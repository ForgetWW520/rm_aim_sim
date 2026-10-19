# C++ 自瞄接入详解

先读 [通用接入流程](integration.md) 和 [协议](protocol.md)。这里给出独立可编译的 Linux C++ 示例，以及如何放进自己的相机、PnP、控制线程；不需要 Godot C++ SDK，也不依赖本项目作者的视觉仓库。

## 1. 编译并跑通完整示例

源码：[examples/cpp/sim_client_demo.cpp](../examples/cpp/sim_client_demo.cpp)。依赖为 C++17、CMake、OpenCV（core/imgproc/highgui）、nlohmann-json 和 Linux 文件 API。仿真本身不需要这些 C++ 依赖；只有编译示例才需要。

Ubuntu / Debian 可安装：

```bash
sudo apt update
sudo apt install build-essential cmake libopencv-dev nlohmann-json3-dev
```

在仓库根目录构建，产物放进已忽略的 `.tools/`：

```bash
cmake -S examples/cpp -B .tools/cpp-demo -DCMAKE_BUILD_TYPE=Release
cmake --build .tools/cpp-demo -j2
.tools/cpp-demo/sim_client_demo --help
```

先按 README 安装 Godot、导入资源。终端一保持图形仿真运行，终端二运行示例：

```bash
# 终端一
./run.sh -- --remote
```

```bash
# 终端二：先接 30 帧，不控制、不开火；无客户端显示也不需要关闭仿真窗口。
.tools/cpp-demo/sim_client_demo --no-display --frames=30 --duration=10

# 上一个退出后：显示 BGR 图像，默认 5 秒退出。
.tools/cpp-demo/sim_client_demo

# 显式启用固定角度测试：yaw 左转 5°、pitch 向下 3°，仍然绝不发射。
.tools/cpp-demo/sim_client_demo --no-display --control --yaw=5 --pitch=3 --duration=3
```

输出 `cpp_camera_demo` 表示实际收到了图像，含宽高、同帧 sim_time、最近接收 seq 与实际云台反馈；最后输出 `cpp_camera_result`。核对 `gimbal.yaw/pitch` 接近约 `0.08727/0.05236` rad，不能只看进程返回 0。示例不做装甲检测、不用真值瞄准，固定角度验证也不等于自瞄跟踪通过。

| 选项 | 默认 / 作用 |
|---|---|
| `--channel=default` | 与仿真 `[ipc].channel` 相同 |
| `--no-display` | 不开客户端 OpenCV 窗口，仿真仍须图形模式 |
| `--frames=30` | 收够帧后退出；默认 0 不限制，若持续时间内没收够则报错 |
| `--duration=5` | 墙钟运行秒数，默认 5，0 表示无限直到帧数满足或 Ctrl+C |
| `--control` | 显式允许固定角度控制，默认关闭 |
| `--yaw=5` / `--pitch=3` | CLI 使用度，内部转协议弧度；默认都是 0 |

带显示时 Q / Esc 退出，也支持 Ctrl+C / SIGTERM 尽力停止并释放锁。所有示例命令都保持 `fire=false`；若要射击，应在自己的算法接好并通过不开火验收后实现开火决策。示例需要真实图像，不能用 `--headless` 仿真来跑。

## 2. 示例代码各部分负责什么

| 接口 | 用途 |
|---|---|
| `LocalSimClient(channel)` | 打开已存在的共享目录，检查 UID/0700，独占 `client.lock`；目录不存在时提示先启动仿真 |
| `poll_state()` | 非阻塞读取新状态，检查协议、首次时间新鲜度、publisher/publication；新状态到达返回 true |
| `state()` | 返回最后状态的 const 引用；仅适用于此示例单线程使用 |
| `fresh()` | 最后新状态的单调接收年龄 ≤200 ms |
| `request_frame()` | 无未完成请求且状态新鲜时，原子发布唯一 request_id |
| `try_frame(SimImage&)` | 非阻塞检查匹配帧，校验上下文、时间、格式、文件大小，读取并转换成独立 BGR；超过 5 秒无响应报错 |
| `send(control,yaw,pitch,...)` | 校验有限数字，携带 publisher/session/严格递增 seq，原子发绝对目标角；可选前馈，始终不开火 |
| 析构 | 尽力发停控、关闭锁与目录；异常同样释放 |

主循环交替 poll 状态、约 50 Hz 发固定测试指令、请求/消费图像，每轮短暂休眠；等待渲染期间不会在一个阻塞函数里卡住 5 秒。示例以 200 ms 为状态/图像年龄界限、以 5 秒为等待失败退出界限，这两个概念不同：**早停控，稍后报断流退出**。

`SimImage` 同时持有 `cv::Mat bgr`、完整的同帧 `metadata` 和客户端单调接收时刻。`cvtColor` 生成客户端自己的图像存储，完成后才清除待处理请求，允许下一次请求确认上一帧已消费。没有把 mmap 的临时内存或 GPU 图像指针交给异步推理。

文件打开使用目录 fd + `openat`，只接受固定 JSON 名和精确匹配的 raw 文件名；使用 `O_NOFOLLOW` 并校验文件类型/长度。写入先完成 `.client.tmp` 再 `renameat`，不原地改最终 JSON。复制这些逻辑时不要去掉原子发布和独占锁。

这是可读、可复用的参考示例，不是完整通用 SDK：没有自动重连、线程安全承诺、任意消息 schema 验证或算法目标管理。遇到格式不符/服务停止会停止并退出，重新启动客户端后再握手；`state()` 引用不能跨线程使用。固定角度测试恢复会话后可继续发送相同测试角，但真实自瞄必须等新观测后才能恢复，见第 6 节。

## 3. 替换自己的相机接口

原来可能是：

```cpp
camera.read(image);
imu = hardware.query_pose(image_time);
```

接入后改为把一帧与它的元数据整体送入流水线，下面片段在 `try_frame` 成功后使用：

```cpp
const auto & meta = sample.metadata;
const auto & camera = meta.at("camera");
const double observed_sim_time = meta.at("sim_time").get<double>();
const auto q = meta.at("gimbal").at("quaternion_wxyz").get<std::vector<double>>();
const auto k = camera.at("K").get<std::vector<double>>();
const auto t = camera.at("t_camera2gimbal").get<std::vector<double>>();
// 验证 q.size()==4、k.size()==9、t.size()==3，所有数有限，标定匹配。
// 然后把 sample.bgr、observed_sim_time、q 与会话标识一起送给检测/PnP。
```

片段中的 `sample` 是 `SimImage`，`q` 是 **w,x,y,z**。若使用 Eigen，要显式构造 `Eigen::Quaterniond(q[0],q[1],q[2],q[3])`，不要把数组误当 x,y,z,w；矩阵映射也要注意 JSON 是行优先，而 Eigen 默认列优先。

`sample.bgr` 为 `CV_8UC3`，不是 RGB、RGBA 或 Bayer。如果推理框架需要 RGB，明确再转一次，避免隐式交换两次。原始输入按完整宽高保存，没有中心裁剪；GUI 主画面为适应窗口可能裁边，不能用 GUI 像素坐标代替输入坐标。

把样本移入队列时可用 `std::move(sample)`；若从此后还要覆盖同一个 `cv::Mat` 缓冲，则先 `clone()`。OpenVINO/TensorRT 异步请求必须保持底层图像/张量存储到推理完成，不能函数返回后释放借用指针。

## 4. 配置 Solver / PnP

使用同帧 `camera.K/distortion/R_camera2gimbal/t_camera2gimbal`，不要沿用实车 YAML。默认标定完整矩阵在 [接入指南](integration.md#第三步对齐内外参与装甲尺寸)。

变换定义如下：

```text
p_gimbal = R_camera2gimbal * p_optical + t_camera2gimbal
p_world  = R_gimbal2world * p_gimbal + gimbal.origin
```

示例片段（已经包含 OpenCV、nlohmann-json，另需 `<vector>`）：

```cpp
auto kvals = sample.metadata.at("camera").at("K").get<std::vector<double>>();
auto dvals = sample.metadata.at("camera").at("distortion").get<std::vector<double>>();
// 先校验尺寸和值；clone 防止 Mat 借用局部 vector 生命周期。
cv::Mat K = cv::Mat(3, 3, CV_64F, kvals.data()).clone();
cv::Mat D = cv::Mat(1, static_cast<int>(dvals.size()), CV_64F, dvals.data()).clone();
```

灯条端点的物体点应与自己的检测角点顺序对应。小装甲为 135×56 mm 的端点矩形，大装甲为 230×56 mm；不是模块外宽高，也不是矩形命中区。TL/TR/BR/BL 是协议理想角点的顺序，算法若使用 BL/TL/TR/BR 应同时调整像点和对应物体点，而不是仅换一边。

自己的坐标若以云台中心为原点，对比 `truth` 时减去 `gimbal.origin`；如果从 optical 直接取 PnP 平移，不要拿它当世界 x/y/z。先用静止场景确认重投影与坐标变换，再测平移和旋转。

## 5. 替换实车下发接口

不要再往真实串口/CAN 写入仿真结果。保留原算法输出，替换最后的通信适配：

```cpp
// 你的算法输出必须先转换为协议的绝对角、单位与符号。
client.send(valid_target, yaw_rad, pitch_rad,
            yaw_velocity_rad_s, pitch_velocity_rad_s,
            yaw_acceleration_rad_s2, pitch_acceleration_rad_s2);
```

注意这个示例的 `send` 永远 `fire=false`。增加自己的开火字段前，先通过固定角度与跟踪验收。真正下发时，`control/fire` 应为 JSON boolean，不能用整型或字符串；角度和前馈都须有限，绝对值 ≤1000，序号须在协议允许范围内。

世界 yaw 正方向向左，pitch 正方向向下；算法使用相反 pitch 时必须反号。`yaw` 为绝对目标角，不是增量或角速度；只有 `yaw_vel` 才是 rad/s 前馈。不要混用 CLI 示例的度与接口的弧度。

确认指令被处理需要读取后续状态：

```text
原子写 command.json
  → state.ipc.last_seq 前进，received 增加
  → state.gimbal 实际姿态逐渐变化
  → 开火许可与发射条件成立后，stats.fired 增加
  → 弹丸结算后，stats.resolved/hit/ground/expired 更新
```

最新值邮箱允许跳过中间指令，不是每一包都执行。`received` 增加但姿态不对时，应继续查角度符号、目标角/实际角、限位、速度/加速度限制与响应；不要停留在 write 成功。

## 6. 接入现有多线程自瞄

示例适合单线程接口联调；实际检测推理耗时较长时，保留项目原有多线程流水线。建议数据结构如下（设计片段，不是仓库额外提供的库）：

```cpp
struct Observation {
  cv::Mat bgr;
  Json frame;  // 同帧 sim_time、姿态、标定、publisher/session
  Clock::time_point received;
  uint64_t generation;
};
// TrackingSnapshot 再携带对应 observation 时间、generation 与不可变目标副本。
```

线程职责：

| 线程 | 负责什么 | 不应被什么阻塞 |
|---|---|---|
| 通信 / 采图 | 读新状态、请求/复制图像，附带同帧元数据 | 长推理、GUI、等待上一帧被跟踪完 |
| 检测 / 跟踪 | 检测、PnP、EKF，发布不可变目标快照 | 控制发送、持锁等待渲染 |
| 控制 | 基于最新 sim_time 预测、检查目标年龄、发送命令 | 下一帧检测、500 ms 的取图等待 |
| GUI | imshow/waitKey 等窗口操作 | 控制循环的锁 |

示例的 `LocalSimClient` **不是线程安全的**。不要让多个线程同时访问其 state/seq/request 或创建多个客户端抢同一个锁。实际改造可选择一个通信线程独占客户端，其他线程通过有锁快照/最新值队列提交数据；或给接口加同步，但只锁短暂状态复制与文件读写，不持锁等待渲染或推理。

控制线程在发包前同时检查：

1. 状态仍在更新，最新 publication 不是重复旧文件。
2. 当前上下文与目标相同：publisher、session、车型/阵营、标定、控制代际一致。
3. 未暂停、外部控制已开启。
4. 图像与目标的墙钟年龄、仿真时间年龄都在项目规定阈值内。
5. 预测输出有限、坐标单位正确，开火额外满足自己的准度/安全条件。

不满足任一条件就停控停火。publisher/session/相机配置变化时递增 generation，丢弃队列与已经在推理但尚未回来的旧结果，重建不兼容的跟踪状态。恢复后要等新帧，不能复用暂停前目标。通信仍活着不能延长旧检测结果的寿命。

`sim_time` 不是 `steady_clock` 的 epoch。若原项目用 `steady_clock::time_point` 接口，要确认算法是否仅用于相对 dt，还是内部会拿真实 now 相减；只有前者才可用约定的合成时间点承载仿真秒。提前量与弹道计算应明确使用最新仿真时间与同帧观测时间，而不是直接套实车墙钟补偿。

## 7. 验证你的适配

按照 [验收顺序](integration.md#验收顺序) 分层测试。针对 C++ 示例，可运行独立通道的自动检查：

```bash
python3 tests/client_examples.py --godot "$PWD/.tools/godot" \
  --cpp-binary "$PWD/.tools/cpp-demo/sim_client_demo"
```

测试启动自己的图形仿真，实际读取 Python/C++ 图像、核对固定角度指令被消费及实际姿态、验证不开火和客户端互斥；不碰默认通道。测试需要图形环境，不是 `--headless` 测试。它不包含任何检测网络，不代表你的自瞄识别/跟踪通过。

如果构建失败，先检查 OpenCV 的开发包/CMake 查找路径、nlohmann-json 开发包和 C++17；如果运行时状态可读但图像超时，查图形仿真、channel 和资源导入，而不是去配置网络端口。显示遇到 Qt/GTK 问题可先用客户端 `--no-display` 排除窗口依赖。
