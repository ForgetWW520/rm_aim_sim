# 本机共享内存协议 v2

本文描述当前 `scripts/bridge.gd`、`camera_stream.gd` 和 `simulation.gd` 的实际接口。初次接入先看 [接入指南](integration.md)，配置字段见 [configuration.md](configuration.md)。不要求特定语言或视觉仓库。

## 传输与文件

仅支持 Linux 同机、同用户的两个进程，不创建 TCP/UDP 接口。`[ipc].channel` 默认为 `default`，双方必须一致；数据位于 `/dev/shm/rm_aim_sim_<channel>/`，目录权限 0700。状态和控制是 tmpfs 中的 UTF-8 JSON 最新值邮箱，图像为原始像素共享内存文件。未处理的旧值被新值替代，不建立队列。

每个通道只允许一个仿真和一个客户端。仿真用 `server.lock/owner.json` 检查存活发布者，异常退出后下一次启动回收遗留文件；客户端以 `flock(client.lock)` 互斥，退出时由内核释放。正常退出删除状态、指令、请求、图像，保留目录和客户端锁文件。旧 v1 网络协议不再支持；原场景配置的 `[network]` 需替换为 `[ipc]`。

写入必须先完成临时文件，再原子 rename 到目标文件。不要原地修改正在发布的文件；这样读取者得到完整旧值或完整新值。状态默认 60 Hz，由 `[ipc].state_hz` 设置，实际发布仍受主循环调度影响。JSON 上限 65536 字节。

| 文件 | 写入者 | 消费者 | 内容 |
|---|---|---|---|
| `state.json` | 仿真 | 客户端 | 最新状态，`type=state` |
| `command.json` | 客户端 | 仿真 | 最新控制指令，`type=command` |
| `request.json` | 客户端 | 仿真 | 单个图像请求，不需要 protocol/type 字段 |
| `frame.json` | 仿真 | 客户端 | 最近请求对应的图像元数据，`type=frame` |
| `frame-<request_id>.raw` | 仿真 | 客户端 | RGB/RGBA 原始像素 |
| `server.lock/owner.json` | 仿真 | 仿真互斥逻辑 | 发布者 PID，用于防止通道冲突和回收崩溃遗留 |
| `client.lock` | 客户端 | 客户端互斥逻辑 | `flock` 的锁文件，持有锁而非文件是否存在表示占用 |

通道名只能包含 1–80 位英文字母、数字、`_` 或 `-`。不要跟其他 UID 共用目录，不要清理活进程的锁。读到缺失、空或损坏文件时应等待下一次发布或按超时停止，不得当作零姿态继续控制。tmpfs 会占用内存；默认 RGB/RGBA 单帧约 4.7/6.2 MB，更高分辨率须关注 `/dev/shm` 空间。

## 坐标与单位

仿真计算统一使用右手 RM 世界系：x 向前，y 向左，z 向上，地面 z=0。距离 m、时间 s、角度 rad、角速度 rad/s、角加速度 rad/s²。yaw 正方向向左，pitch **向下为正**。

枪口方向：

```text
direction = [cos(pitch)*cos(yaw), cos(pitch)*sin(yaw), -sin(pitch)]
```

世界系到 Godot 仅用于显示：`(x, y, z) -> (-y, z, -x)`。控制端不要使用 Godot 显示坐标。

`gimbal.quaternion_wxyz` 是云台系到 RM 世界系的旋转四元数，排列 `[w,x,y,z]`，不包含平移。云台原点通过 `gimbal.origin` 单独给出。初始 yaw 为世界 +x，初始 pitch 为 0。

**接现有视觉仓库时需要确认原点**：本仿真的世界原点在地面。若算法的位置以云台旋转中心为原点，与世界真值对比时应减去 `gimbal.origin`。图像模式应配置与虚拟相机一致的内外参，不直接复用实车标定。指令中的 yaw/pitch 是绝对目标角，不是相对增量。

四元数对应 `R_world_gimbal = Rz(yaw) * Ry(pitch)`，因此正 pitch 把前向转到 -z。所有三维位置数组与法向数组排列为 `[x,y,z]`，矩阵数组为行优先；事件与真值点使用 RM 世界系，不使用 Godot 显示轴。

## 指令

```json
{
  "protocol": "rm_aim_sim/2",
  "type": "command",
  "session_id": "从最新状态读取",
  "publisher_id": "从最新状态读取",
  "seq": 1,
  "control": true,
  "fire": false,
  "yaw": 0.02,
  "pitch": -0.01,
  "yaw_vel": 0.0,
  "pitch_vel": 0.0,
  "yaw_acc": 0.0,
  "pitch_acc": 0.0
}
```

向 `command.json` 原子写入。`publisher_id/session_id/seq/control/fire/yaw/pitch` 必填；速度和加速度可省略，默认为 0。control/fire 必须是 JSON 布尔，角度等必须是有限数值；数值绝对值大于 1000 的包被拒绝。yaw 归一化到 [-π,π)，pitch 按机械限位截断。未定义的额外字段忽略。

`seq` 必须是 [0,2⁵³-1] 内严格递增的整数，可从 0 开始。重复、倒序、旧 session、无效数字与暂停期间的包拒绝，且不刷新看门狗。启用外部控制后，本地操作停止下发云台指令；关闭外部控制会停止发射，再恢复本地操作。

| 字段 | 类型 | 作用 |
|---|---|---|
| `protocol`, `type` | string | 必须为 `rm_aim_sim/2`、`command` |
| `publisher_id`, `session_id` | string | 从当前新鲜状态原样复制，不能使用重启/重置前的值 |
| `seq` | integer | 在本会话内大于接收端 last_seq；允许跳号，不能重复 |
| `control`, `fire` | boolean | 控制使能 / 持续开火许可，不能用 0/1 或字符串代替 |
| `yaw`, `pitch` | number | 绝对目标角 rad，必填 |
| `yaw_vel`, `pitch_vel` | number | 可选的目标轨迹角速度 rad/s，默认 0 |
| `yaw_acc`, `pitch_acc` | number | 可选的目标轨迹角加速度 rad/s²，默认 0 |

前馈参与二阶伺服：`a = w²*(goal-angle) + 2*w*(goal_v-actual_v) + goal_a`，`w=2π*response_hz`，然后施加配置的加速度/速度限制。yaw 误差取最短绕回角。指令不是瞬间传送姿态，实际值通过后续 gimbal 反馈。

`fire=true` 按 `weapon.rate` 周期触发，再延迟 `weapon.delay` 出膛；`fire=false` 只停止新增触发，已接受的待出膛仍会完成。`control=false` 同时清除待出膛并令 fire 无效，云台按限加速度减速，不是角速度瞬间归零。在飞弹丸不因停控或停火消失。

有效指令超时默认 250 ms，按接收端的单调墙钟计算，超时取消待出膛并停止控制/发射；已经在飞行的弹丸继续完成碰撞判定。暂停和恢复期间保持窗口与 IPC 轮询工作，不积累发射指令。重置、切换本地/外部控制和暂停/恢复会产生新的 session，客户端读取最新状态并重新开始序号。界面参数即时生效，保留 session、仿真时间、在飞弹丸与累计统计。客户端自身重启但场景未重置时，可以从状态中的 `ipc.last_seq+1` 继续。

注意：指令文件写成功不等于被接收。读取后续 `ipc.last_seq/received/rejected/status` 核对；重复文件内容不会每轮重新消费。没有逐包可靠队列或 ACK 消息，`last_seq` 是最近有效指令号，期间跳号是最新值覆盖的正常结果。关闭外部控制或 paused 时包被拒绝，不应靠持续发送旧包等待恢复。

## 状态

读取 `state.json`。主要字段：

| 字段 | 含义 |
|---|---|
| `protocol / type` | `rm_aim_sim/2` / `state` |
| `session_id` | 当前场景/控制会话，重置后不得复用旧指令 |
| `sim_time / tick / paused` | 仿真时间、物理外层步号、暂停标志 |
| `publisher_id / publication` | 当前发布进程标识 / 状态发布序号，用于辨认重复值和进程重启 |
| `wall_unix_sec` | 同机 Unix 时间秒，用于拒绝首次连接时的崩溃遗留状态；收到新发布后用接收端单调钟计超时 |
| `gimbal` | 实际 yaw/pitch、实际角速度、世界原点、wxyz 四元数 |
| `weapon` | 弹速、射频、发射延迟、枪管长度、重力、单发基础伤害 `damage` |
| `health` | 当前血量 `current`、上限 `maximum`、存活 `alive`、战亡仿真时间 `death_time`（未战亡为 -1） |
| `appearance` | 车型、红蓝方、外观模型配置 |
| `truth` | 当前靶车中心、旋转角、四块装甲中心与外法向，仅供调试评分 |
| `camera` | 当前虚拟相机的理想标定和可见装甲关键点 |
| `stats` | 累计出膛、命中、各类未命中、飞行/待出膛、命中率、实际扣血 `damage`、击毁 `kills` |
| `events` | 最近 128 条发射/碰撞/设置血量事件，每个包可能重复携带同一事件 |
| `ipc` | 外部控制状态、最后接收序号、接收/拒绝计数 |

`truth.armors[].normal_yaw` 是外法向方位角。现有视觉 Target 使用的装甲 yaw 约定应在适配时明确换算，不能直接假定两者同向。

### 嵌套字段参考

下列计数、索引、tick、publication 是非负整数，`last_seq` 未收到有效指令时为 -1；时间/角度/位置为数值。不要依赖 JSON 对象字段顺序。

| 对象 | 字段与含义 |
|---|---|
| `gimbal` | `yaw/pitch` 实际角 rad；`yaw_vel/pitch_vel` 实际角速度 rad/s；`origin` 世界位置三元数组；`quaternion_wxyz` 四元数四元数组 |
| `weapon` | `speed` m/s、`rate` Hz、`delay` s、`barrel_length` m、`gravity` m/s²、`damage` HP；不包含 lifetime |
| `health` | `current/maximum` 整数 HP，`alive` boolean，`death_time` 仿真秒，未死亡为 -1 |
| `appearance` | `robot/team/armor_model/body_model` 字符串、`armor_scale/body_scale` 数值；body 字段为不加载的历史配置 |
| `truth` | `center` 轨迹当前中心 `[x,y,z]`；`angle` 当前旋转角 rad；`armors` 始终有 4 个元素 |
| `truth.armors[]` | `id` 0–3；`center` 装甲中心；`normal` 外侧单位法向；`normal_yaw` 外法向方位角 |
| `ipc`（状态） | `enabled` boolean，`status` 显示文本，`last_seq` 最近有效序号，`received/rejected` 累计接收/拒绝次数 |
| `camera` | 见相机字段表；图像不在 state.json 内 |

不要将 `ipc.status` 中文文本当作稳定的枚举。`enabled` 只表示外部模式开启，不表示当前一定有有效目标或云台正在跟踪。接收/拒绝计数是 bridge 生命周期累计值，不应假设重置本轮后归零。

### 统计

| 字段 | 含义 |
|---|---|
| `fired` | 已实际出膛的弹丸数，待出膛不计 |
| `hit` | 已结算的装甲几何命中数，包括战亡后的几何命中 |
| `body` | 兼容字段，当前没有车体碰撞，保持 0 |
| `ground` | 已结算的落地数 |
| `expired` | 已结算的超时/越界清除数 |
| `resolved` | `hit + body + ground + expired` |
| `in_flight` | 尚未结算的在飞弹丸数 |
| `pending` | 已触发、尚未出膛的延迟事件数 |
| `hit_rate` | `hit/resolved`，0–1；resolved=0 时为 0 |
| `hits_per_second` | `hit/sim_time`，全轮均值，不是滑窗频率 |
| `first_hit_time` | 本轮首次装甲命中的仿真秒，无命中为 -1 |
| `damage` | 累计实际扣血，末发按剩余血量截断 |
| `kills` | 血量从正数变成 0 的次数 |

始终有 `fired = resolved + in_flight`；pending 不计入 fired。重置会清空本轮统计，暂停不清空。不要把尚未结算的弹丸当作未命中。

### 事件

事件以 `(session_id, type, id)` 去重，同一弹丸具有一次 shot 和一次 impact。impact 的 `kind` 为 `hit/body/ground/expired`，装甲命中另含 `armor_id`，并含本次实际扣血 `damage`、扣血后 `health`、是否造成战亡 `killed`。事件时间是仿真秒，point 是 RM 世界坐标。`health_set` 事件使用独立递增 id，包含设置后的 `health/max_health`，用于记录界面修改血量及切换兵种。

| type | 字段 |
|---|---|
| `shot` | `id/time/yaw/pitch`；角度为出膛时的实际角，id 为本轮弹丸号 |
| `impact` | `id/time/kind/point/armor_id/damage/health/killed`；未命中 armor_id 为 -1；expired 另有 reason |
| `health_set` | `id/time/health/max_health`；id 与弹丸号是不同计数器 |

事件环最多保存 128 条，不是保证不丢失的事件总线；慢客户端可能错过事件，总计分应读 stats。会话在暂停/恢复时也变化，但已保存的事件可能仍重复出现在后续状态中，跨会话合并事件时不能只靠新的 session 就把重复历史重新计分；单会话去重及按本轮导出分析最简单。若需要完整连续日志，客户端应及时记录发布并用本轮重置边界区分 id。

`expired` 同时表示超过寿命及飞出靶车完整运动范围后清除，`reason` 分别为 `lifetime/range`。两者均结算为未命中，不清空统计，不生成新 session。本地 F 跟踪辅助不影响外部控制模式。

默认血量与基础伤害取 RMUL 2026 的 3V3 无增益规则。伤害在出膛时固定；血量归零后几何命中仍计数，实际伤害为 0，击毁不重复累计。界面设置血量会设置当前血量及上限并保留统计；重置本轮恢复配置血量、清空统计。

战亡后目标在碰撞时的位置和角度停止，平移、自转配置开关和速度值保留；重置后按保存设置继续运动。显示层的反弹不产生第二条计分事件。当前目标只有四块装甲，没有车体碰撞；`stats.body` 及 `kind=body` 保留为协议兼容字段，当前运行中不会新增车体命中。

存活时 `kind=hit` 使对应 `armor_id` 的灯条与光晕从碰撞时刻起熄灭 0.05 仿真秒，然后恢复阵营色；连续命中延长到最后一次命中后的 0.05 秒。暂停冻结计时，普通参数修改和显示模型重建不清除闪烁，显式恢复血量或重置本轮会清除。致死后所有灯条持续关闭。灯控同时作用于场景材质、相机曝光模型中的 LED 信号和理想灯条观测，不隐藏板体或改变碰撞几何、扣血与事件语义；该时长仅为仿真表现参数。

## 相机

相机采用针孔模型，默认 1440×1080，垂直 FOV 45°，零畸变。内参 K 为 3×3 行优先数组；`fx=fy=height/(2*tan(vfov/2))`，主点 `(width/2,height/2)`。相机 optical 系 x 右、y 下、z 前。

`[camera].brightness_gain` 为相机曝光增益，范围 0–4，默认 0.4；低于 1 减少曝光，0 全黑，高于 1 增加曝光。相机输出端使用简化成像模型：反射背景与贴图转为线性信号，根据可见灯条的投影合成高于传感器饱和点的自发光信号，统一乘曝光增益，再饱和截断并转为 sRGB。因此低曝光下背景和数字会暗下去，灯条仍可保持高亮；场景光照和第三人称材质不变。这是针对内置灯条的曝光外观近似，不是经标定的光学 HDR，也不模拟传感器噪声或曝光时间引起的运动模糊。预览和共享内存复用同一渲染结果，`camera.brightness_gain` 记录采样时的值；不影响 K、分辨率、几何或理想四角。

`camera.origin` 是当前光心在 RM 世界系的位置，yaw/pitch 是相机随云台的旋转。配置 `[camera].offset` 是以云台系 x 前、y 左、z 上定义的光心安装偏移，默认 `(0.08,0,0.04)` m；相机与云台无额外安装角。理想 optical→gimbal 旋转为：

```text
[ 0  0  1 ]
[-1  0  0 ]
[ 0 -1  0 ]
```

`camera.armors[].corners` 是灯条上下端点组成的四角，顺序为 TL/TR/BR/BL，坐标为像素。它使用 `lightbar_spacing/lightbar_length`，不使用模块外宽高或碰撞区宽高。只输出存活、灯条点亮、正面可见且四角完整落在视场中的装甲；命中闪烁熄灯期间不输出该块，血量归零后列表为空，`truth.armors` 始终保留。未加入噪声、随机漏检、随机延迟或外部车体模型的完整遮挡测试。

状态的 camera 字段是理想观测，不包含图像字节。实际渲染图像通过下面的本机共享内存提供。`camera` 同时带 `R_camera2gimbal`（3×3 行优先）与 `t_camera2gimbal`（m），供视觉端校验配置。

| camera 字段 | 类型 / 单位 |
|---|---|
| `timestamp/tick` | 对应采样的 sim_time / 外层物理步号 |
| `width/height` | 整数像素 |
| `brightness_gain` | 曝光倍率 |
| `K` | 9 个数，3×3 行优先 |
| `distortion` | 5 个零，对应无畸变针孔模型 |
| `R_camera2gimbal` | 9 个数，3×3 行优先旋转 |
| `t_camera2gimbal` | 3 个数，云台系安装平移 m |
| `origin/yaw/pitch` | 当前世界光心三元数组 / 随云台转动的实际角 rad |
| `armors` | 诊断用理想观测列表，可为空 |
| `armors[].id` | 几何装甲索引 0–3，**不是**机器人编号 |
| `armors[].corners` | 4×2 数组，像素 u 右/v 下，TL/TR/BR/BL |

机器人编号由 `appearance.robot` 解释：infantry_3/4/5、hero(1)、sentry(7)。本协议不定义你模型内部的类别或颜色整数枚举。

## 实时相机图像

`--headless` 或 `--no-ipc` 不提供图像。图形模式的消费流程：

1. 读取新鲜 `state.json`，取得 `publisher_id`。
2. 向 `request.json` 原子写入 `{"publisher_id":"…","request_id":"客户端唯一标识-递增序号"}`。request_id 只允许字母、数字、下划线、连字符，长度 1–80。
3. 等待 `frame.json` 中的 publisher_id 和 request_id 均与请求一致。
4. 打开同目录 `frame-<request_id>.raw`，校验大小等于 `image_bytes`，读取或 mmap，再复制到消费端自有图像；RGB/RGBA 按需转换成 BGR。
5. 完成复制后才发送下一次请求。可在推理前预取，最多提前一帧。下一请求同时确认上一帧已读取；发布下一帧后删除上一帧文件，不随时间积压图像。

`frame.json` 为 `protocol=rm_aim_sim/2`、`type=frame`，带 `encoding=rgb8/rgba8`、`frame_file/image_bytes/request_id/publisher_id`；像素按行紧密排列、左上角起始，无压缩、无 JPEG 编解码。文件名和大小必须与请求及相机宽高/通道数一致。每帧使用唯一文件名，避免元数据与不同尺寸像素错配；已打开的 inode 即使被删除仍可完成读取。

其他元数据来自采样时的状态，去掉 `truth/events`。`camera.armors` 仍是诊断用理想角点，实际图像模式不应代替检测结果。`ipc` 包含 `enabled/last_seq`。世界姿态、相机姿态、tick、sim_time 和标定先固定，再在 `frame_post_draw` 后读回对应帧，不能用最新状态的姿态替换图像采样姿态。图像不叠加界面或准星。

注意 frame 元数据不是逐字复制最新 state：它没有 `publication/wall_unix_sec`，也没有 `ipc.status/received/rejected`。图像新鲜度应用 `(publisher,session,request_id)`、采样时间以及客户端单调接收时刻判断，不要对 frame 强行使用状态包的 publication 校验。

### 图像握手示例

```json
{"publisher_id":"从状态读取","request_id":"myclient-000001"}
```

收到的 `frame.json` 会包含以下字段（仅列结构示意，其余 metadata 按上文；实际尺寸与大小必须校验）：

```json
{
  "protocol": "rm_aim_sim/2",
  "type": "frame",
  "publisher_id": "从状态读取",
  "session_id": "采样时会话",
  "request_id": "myclient-000001",
  "frame_file": "frame-myclient-000001.raw",
  "encoding": "rgb8",
  "image_bytes": 4665600,
  "sim_time": 1.0,
  "tick": 240,
  "camera": {"width": 1440, "height": 1080}
}
```

`image_bytes = width * height * channels`，rgb8 为 3、rgba8 为 4。每个通道 8 位，无行填充、无文件头；不是 PNG/视频，不能直接用 `imread()` 解码。上例中的 camera 仅为简写，实际含完整标定等字段。

只在收到新请求时读回/发布图像，无新请求时不继续生成原始帧文件。相机 3D 场景只渲染一次：第一人称主视图显示未经曝光处理的原图，另一个仅 2D 的 GPU 处理视口生成曝光图，供右上相机预览和共享内存输出复用。调节曝光不改变第一人称主画面的亮度。第一人称关闭根视口的重复 3D 渲染；第三人称恢复独立主相机。主视图按比例覆盖窗口，必要时裁边；传给视觉的图像始终保留完整相机分辨率。显存读回、tmpfs 写入与消费端像素复制仍有开销，不是零拷贝或硬实时。帧的 `capture_timing` 包含 `render_ms/readback_ms/publish_ms/raw_bytes`。

默认相机及 `configs/vision.cfg` 均为 1440×1080、垂直 FOV 45°，与视觉仓库 `configs/sim.conf` 配对。界面支持实时选择 640×480、960×600、1280×720、1280×1024、1440×1080、1920×1080 或输入自定义宽高；切换不重置会话、血量或统计。视场角固定时按新高度计算 fx/fy，并更新主点；自瞄配置需保持一致，适配层不修改检测坐标或标定。

## 时钟与复现

仿真采用 240 Hz 固定外层物理步，内部碰撞子步不大于 1 ms。真实显示帧率与物理步分开，暂停时 `sim_time` 不变。负载过高时仿真时间可能落后于墙钟，本版本不保证硬实时。

接入的滤波器/提前量模块如果内部自行读取 `steady_clock::now()`，不能直接把 `sim_time` 当成同一个时钟。应使用显式仿真时间、回放入口或明确的时间域适配；暂停、重置后时间关系可能改变。协议本身不要求某个项目的固定毫秒补偿。暂停、重置和外部控制切换后，用新 session 丢弃旧帧和旧跟踪状态。

### 客户端恢复规则

| 条件 | 应采取的动作 |
|---|---|
| publication 不再变化 / 状态超时 | 停控停火；不能因重复读到文件而刷新状态年龄 |
| 状态更新、相机/跟踪停更 | 目标独立超时，停止旧目标控制 |
| publisher 改变 | 发布者重启：丢弃旧请求/帧/跟踪，重新读新状态并握手 |
| session 改变 | 控制上下文改变：清空旧目标，重新同步 seq，等待新观测 |
| paused / 外部控制关闭 | 停控停火，恢复后不复用旧观测 |
| 车型/阵营或相机标定改变 | 即使 session 未变也要清空不兼容状态并校验配置 |

新请求应使用新的唯一 request_id，超时后不能等同名旧文件冒充新帧。客户端自己的 watchdog 用单调钟；`wall_unix_sec` 仅辅助初次拒绝崩溃遗留状态，不能拿系统时钟跳变计算控制 dt。恢复安全控制需要新状态和新观测，不只是重新写同一条 command。

## 验证与性能边界

传输、实际姿态、出膛、命中、扣血与失联保护由 `tests/integration.py` 验证，图形相机由 `tests/ui_smoke.gd -- --no-ipc --camera-only` 及接图示例验证。具体命令见 README。它们不验证某个外部检测网络的识别率。

相机需要渲染、GPU 读回、tmpfs 发布、像素复制/转换；状态频率、控制发送频率、相机帧率与检测帧率是不同指标。这里不提供与宿主机/模型无关的 FPS 保证，也不把历史单次测试值当作性能承诺。调试建议分别记录 `capture_timing`、接收/复制、检测、跟踪和控制耗时，再比较相同配置和负载。
