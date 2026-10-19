# 把自己的自瞄接入仿真

本指南不要求使用某个视觉仓库。仿真与自瞄是两个独立进程，推荐保留原来的检测、PnP、跟踪与决策代码，只替换相机和云台通信适配层。完整字段与校验规则见 [协议](protocol.md)，启动和场景参数见 [配置参考](configuration.md)。

## 先选验证模式

| 模式 | 输入 | 启动仿真 | 适合验证 |
|---|---|---|---|
| 真实图像 | `frame-*.raw` 与同帧 `frame.json` | 图形模式 `./run.sh -- --remote` | 检测、PnP、跟踪、提前量、控制闭环 |
| 理想二维角点 | `state.camera.armors` | 可用 `./run.sh --headless -- --remote` | 绕过检测，排查 PnP/后端 |
| 世界真值 | `state.truth` | 可无界面 | 单独测试控制/弹道、评分；不能算视觉识别效果 |

三种模式的命中率不能混在一起比较。相机接图示例只是第一种模式的输入检查，不内置检测器或自动瞄准。

## 第一步：确认控制与图像接口

完成 README 的资源导入后，在两个终端依次执行：

```bash
# 终端一：保持此图形窗口运行。
./run.sh -- --remote
```

```bash
# 终端二：角度选项为度；协议中的角度为弧度。不自动开火。
python3 tools/control_demo.py --yaw=5 --pitch=3 --duration=3
# 上一个退出后再运行：仅接图，标准库即可。
python3 tools/camera_demo.py --no-display --frames=30
```

控制示例的输出应显示实际姿态向设定值靠近。接图示例应打印真实收到的宽高、编码、字节数和仿真时间；可去掉 `--no-display` 看图，但须先安装 README 中的 NumPy/OpenCV 依赖。

`--remote` 相当于打开界面的“本机自瞄控制”。通道默认 `default`，两边必须相同；同通道只能运行一个控制端。示例与自己的自瞄要交替运行，不能一起抢占。更换通道的方法见[配置参考](configuration.md#同时运行多组仿真)。

## 第二步：替换相机输入

### Python：复用现成客户端

完整可运行代码是 [tools/camera_demo.py](../tools/camera_demo.py)。下面是其核心取图逻辑；在仓库根目录运行 Python 时可以这样导入：

```python
from tools.local_ipc import LocalClient
import cv2
import numpy as np

client = LocalClient("default")
try:
    state = client.read_state()
    request_id = client.request_frame()
    frame, pixels = client.receive_frame(request_id)
    channels = {"rgb8": 3, "rgba8": 4}[frame["encoding"]]
    camera = frame["camera"]
    rgb = np.frombuffer(pixels, np.uint8).reshape(
        camera["height"], camera["width"], channels)
    conversion = cv2.COLOR_RGB2BGR if channels == 3 else cv2.COLOR_RGBA2BGR
    bgr = cv2.cvtColor(rgb, conversion)
    # 把 bgr、frame['sim_time']、frame['gimbal'] 作为一个样本送入算法。
finally:
    client.close()
```

`pixels` 是已复制到客户端的 bytes；转换后的 BGR 是独立图像。不要把 RGB 字节直接按 BGR 使用，否则红蓝会颠倒。图像没有 UI、准星或叠加标注。

`LocalClient` 的方法约定：

| 方法 | 返回 / 行为 |
|---|---|
| `LocalClient(channel="default", timeout=8)` | 等待目录，校验同用户/0700，独占 `client.lock`；等待失败抛 `TimeoutError`，锁冲突抛 `OSError` |
| `read_state(timeout=3)` | 等待新的 publisher/publication，要求 Unix 时间新鲜，更新 `client.state`；超时抛 `TimeoutError` |
| `send(control=True, fire=False, yaw=0., pitch=0., **extra)` | 基于最后读取的状态填写 session/publisher/递增 seq，原子发布；不代表指令已被仿真接受 |
| `request_frame()` | 基于最后读取的状态发请求，返回唯一 request_id |
| `receive_frame(request_id, timeout=5)` | 等待对应帧并校验 publisher、文件名和大小，返回 `(metadata, bytes)` |
| `close()` | 若已有状态，尝试发布停止指令，再释放锁；退出时应在 finally 调用 |

这是便于理解的参考客户端，不是自动重连 SDK：它没有后台保活，也不替你丢弃过期目标。接收方法会阻塞；如果把推理/取图和控制串在同一线程，超过默认 250 ms 就可能触发停火。服务重启、文件消失或读图超时时应停止控制，退出并重新创建客户端、重新读状态，而不是无条件续用旧图像。生产适配还应增加下面的生命周期保护。

### C++ / 其他语言：实现同一份邮箱协议

**C++ 用户可直接从[独立完整示例与详细教程](cpp_integration.md)开始**，包含 CMake 构建、固定角度控制回读、OpenCV/PnP 及现有多线程工程的适配。下面说明跨语言实现都应满足的流程。

无需链接 Godot SDK，也没有必须安装的仿真 C++ 库。使用文件 I/O、JSON 库、`flock` 和可选的 `mmap` 即可：

1. 检查 `/dev/shm/rm_aim_sim_<channel>/` 属于当前 UID、权限 0700，独占 `client.lock`（`LOCK_EX | LOCK_NB`），不删除别人的锁。
2. 读取新鲜状态，记住 `publisher_id/session_id/publication`。用单调钟记录最后一次新发布的接收时刻；反复读取同一 publication 不是新反馈。
3. 将含 publisher_id 与唯一 request_id 的 JSON 原子写入 `request.json`。
4. 轮询 `frame.json`，匹配 publisher/request；只打开准确的 `frame-<request_id>.raw`，校验宽高、编码、字节数，拒绝路径穿越或异常大小。
5. 读取或 mmap 像素；复制/转换成算法自己的图像，再发布下一请求。下一请求是“上一帧已复制”的确认，不是无限帧队列。
6. 将图像、**该帧**姿态、时间、标定与会话标识一起传递。不要出队后再用最新状态覆盖姿态。

例如已完成上述校验并持有有效映射时，OpenCV 转换部分是：

```cpp
// 片段：mapped_bytes/width/height 必须已根据 frame.json 与文件大小校验。
const int channels = encoding == "rgb8" ? 3 : 4;  // encoding 仅允许 rgb8/rgba8
cv::Mat rgb(height, width, CV_MAKETYPE(CV_8U, channels), mapped_bytes);
cv::Mat bgr;
cv::cvtColor(rgb, bgr, channels == 3 ? cv::COLOR_RGB2BGR : cv::COLOR_RGBA2BGR);
// bgr 拥有自己的存储；此时才可以 munmap 并发下一请求。
```

上面只是 OpenCV 片段；可复用的完整单线程参考客户端见 `examples/cpp/sim_client_demo.cpp`。写 JSON 使用同目录临时文件，关闭后 `rename`；不得边写边让仿真读取最终文件。完整包格式见 [protocol.md](protocol.md)。

## 第三步：对齐内外参与装甲尺寸

默认参数如下，**每帧的 camera 元数据才是当前有效值**，修改分辨率/FOV/安装位置后须同步配置或清空旧跟踪状态后重建解算器。

| 项目 | 默认值 |
|---|---|
| 分辨率 / 垂直 FOV | 1440×1080 / 45° |
| `fx = fy` | `1080 / (2*tan(45°/2)) = 1303.6753236814714` |
| `cx, cy` | 720, 540 |
| 畸变 | `[0, 0, 0, 0, 0]` |
| 光心在云台系的偏移 | `[0.08, 0, 0.04]` m |
| 云台世界原点 | `[0, 0, 0.65]` m |
| 小装甲灯条中心间距 / 长度 | 0.135 m / 0.056 m |
| 大装甲灯条中心间距 / 长度 | 0.230 m / 0.056 m |
| 装甲内倾 | 15° |

```text
K = [1303.6753236814714, 0, 720,
     0, 1303.6753236814714, 540,
     0, 0, 1]

R_camera2gimbal = [ 0,  0, 1,
                  -1,  0, 0,
                   0, -1, 0]
t_camera2gimbal = [0.08, 0, 0.04]
```

camera optical 系为 x 右、y 下、z 前；gimbal 和 RM world 都是 x 前、y 左、z 上。变换的含义是：

```text
p_gimbal = R_camera2gimbal * p_camera + t_camera2gimbal
p_world  = R_gimbal2world * p_gimbal + gimbal.origin
```

`gimbal.quaternion_wxyz` 给出 `R_gimbal2world`，顺序是 **w,x,y,z**，不是 x,y,z,w。仿真不额外模拟 IMU 安装偏角；如果现有流程必须通过 IMU 中间系，可将它与云台系对齐，不能继续带入实车的安装偏角。

世界原点在地面；若你的“世界系”以云台中心为原点，对比真值时要减去 `gimbal.origin`。yaw 向左为正，pitch **向下为正**；算法输出若为抬头正，需要反号。协议发送的是世界参考的绝对云台目标角，不是相对角增量。

PnP 模型应使用灯条关键点几何，不要把模块外形 140×125 mm 当作 135×56 mm 的灯条端点矩形。理想角点按 TL/TR/BR/BL 给出；自己的检测器和 PnP 模型点顺序若不同，必须重排。你可以缩放图像，但须同步缩放 K 和像素点；仿真不会替你修改坐标。

## 第四步：替换云台通信

按周期读取反馈，再发送绝对目标角；`control_demo.py` 是可执行参考。Python 核心调用为：

```python
state = client.read_state()
if state["ipc"]["enabled"] and not state["paused"]:
    # yaw/pitch 为你的算法结果，单位 rad；初次联调先让 fire=False。
    client.send(control=True, fire=False, yaw=yaw, pitch=pitch,
                yaw_vel=0.0, pitch_vel=0.0, yaw_acc=0.0, pitch_acc=0.0)
else:
    client.send(control=False, fire=False)
```

角速度与角加速度是可选的目标轨迹前馈（rad/s、rad/s²），不填为 0。若你的控制器已经输出这些量，可对齐单位与符号后发送；只传角度也合法，但实际云台仍有响应迟滞，不能把目标角当实际姿态。相机和枪口使用实际姿态。

弹速、射频、发射延迟和重力取当前 `state.weapon`，不要写死为实车值。`fire=true` 是持续射击许可，仿真按配置射频触发，不是“收到一包就打一发”。`fire=false` 停止新增触发，但已排队的延迟出膛仍会完成；`control=false`、暂停或失联会取消待出膛指令，已经在飞的弹丸仍正常结算。

写邮箱成功不等于控制成功。应读取后续 `state.ipc.last_seq/received/rejected/status`，确认接收端消费了包，再看实际 yaw/pitch 是否变化，最后看 `stats.fired/hit/resolved`。邮箱是最新值模式，跳过中间 seq 正常；控制发送得快不等于所有命令都被执行。

## 时钟、线程与生命周期保护

建议把链路拆成三个职责，算法已有线程结构时直接复用：

```text
采图/推理 → 跟踪快照（图像时间、会话、目标） → 周期控制/发送
                                                  ↑
                                         最新状态与超时检查
```

- `frame.sim_time` 用于该图像的观测/滤波时间，最新 `state.sim_time` 用于估计观测到当前的仿真时延；弹道与提前量也在仿真时间域计算。
- 墙钟仅用于线程节拍、等待和通信看门狗。不要直接拿 `steady_clock::now()` 减 `sim_time`；现有算法若内部读墙钟，须使用回放/显式时间入口或实现明确的时间域适配，不能伪造一个固定偏移就认为暂停后仍正确。
- 不在持有通信锁时等待图像、推理或做耗时后处理，避免控制线程被阻塞。不要仅靠提高发送线程频率掩盖旧目标。
- 默认状态发布约 60 Hz、指令看门狗 250 ms。可先用 50–100 Hz 的控制循环，并设置低于或等于看门狗量级的目标失效阈值；具体频率取决于算法和负载，不保证硬实时。
- 分别检查“状态新鲜”和“图像/目标新鲜”。状态仍更新不代表检测仍在更新。过期目标必须停控停火，不能无限外推。
- `publisher_id`、`session_id` 改变时，丢弃排队图像、未完成推理结果和跟踪状态，重新同步序号；暂停、外部控制关闭、状态断流时立即停控停火。
- 车型/阵营、分辨率、内外参等运行时修改不一定改变 session。接入端要额外检测相关配置变化，失配时停控并重建；恢复后只接受新观测。
- 退出时尽力发 `control=false, fire=false` 再释放锁。进程崩溃由接收端看门狗兜底；不要依赖退出包一定送达。

## 验收顺序

1. **通信**：固定目标角、不开火。确认收到 seq，实际姿态靠近目标，停止客户端后不再出膛。
2. **相机**：运行接图示例，核对分辨率、RGB/BGR、曝光及 K；右上预览应与输入图像一致，不拿第一人称主画面判断曝光。
3. **PnP**：静止、不开火，对比重投影和真值误差。真值只用于评估；不要一边喂真值、一边报告图像识别精度。
4. **跟踪/控制**：静止 → 平移 → 自转 → 组合，分别检查抖动、换向、观测延迟、控制响应与前馈。先关火隔离命中灭灯造成的暂时漏检。
5. **射击**：开启算法的开火判断，核对弹速/射频/发射延迟；命中率是 `hit / resolved`，不是 `hit / fired`。确认 `fired = resolved + in_flight`。
6. **异常**：暂停/恢复、重置、外部控制开关、断相机、服务重启、切换车型/分辨率。旧目标不得恢复控制；新会话要等新观测。

接口闭环的仓库测试：

```bash
./run.sh --headless --script res://tests/run_tests.gd
python3 tests/integration.py --godot "$PWD/.tools/godot"
```

它们验证仿真核心和共享内存闭环，不证明你的检测模型或自瞄算法已通过。图形相机检查另见 README 的验证命令。

## 常见问题

| 现象 | 先检查什么 |
|---|---|
| 找不到仿真 / 等状态超时 | Linux、同用户、channel 一致、仿真日志是否 ready、目录权限与新 publication；不要拿旧文件存在当作进程存活 |
| 已取图但云台不动 | `ipc.enabled`、paused、session/publisher、seq、弧度单位、`control` 是否真布尔、`rejected/status` |
| 收到状态但相机超时 | 仿真不能 `--headless` 或 `--no-ipc`；检查资源导入、图形驱动、request_id 和 publisher 匹配 |
| 红蓝颠倒 | rgb8/rgba8 是否转换为 BGR，算法颜色枚举是否与自己项目一致 |
| 越远越不准 / 高度偏差 | K、分辨率/FOV、灯条点模型尺寸、pitch 符号、光心偏移、地面/云台原点差异 |
| 运行一会儿停火 | 状态/目标年龄、指令发送是否被取图或推理阻塞；不要通过增大超时来隐藏断流 |
| 有效包数量少于发送数 | 最新值邮箱会覆盖旧值，非命令队列；看最新 last_seq 与实际状态而非要求逐包确认 |
| 有时识别丢失 | 自定义模型域差异、曝光/距离、姿态、命中灭灯 50 ms 或战亡；先不开火测试 |
| 固定靶也抖 / 换向跟不准 | 分开看检测/PnP/估计目标、期望角和实际角；噪声、运动模型与伺服响应都可能影响，不能仅凭画面归因 |
| 另一个客户端启动报锁冲突 | 关闭原客户端或选独立通道；不要删除仍被活进程持有的锁 |

## 哪些功能不在本仓库内

本仓库不提供通用检测模型、ROS 节点、跨机器传输或某个实车项目的完整适配代码。`rm_vision` 的 `auto_aim_sim/mt_standard_sim` 是已有接入方式的例子，不是本仓库的可执行程序；不需要克隆它才能使用此仿真。自己的识别率、跟踪状态与开火策略应由自己的项目测试。
