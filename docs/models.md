# 装甲外观与替换

当前目标只包含四块装甲，不显示车体，也没有隐藏的车体碰撞。装甲外观与运动、命中判定分别配置。

## 选择自定义装甲

点击“选择装甲 GLB/glTF”，选择后立即生效；“恢复内置外观”恢复兵种贴图。外部文件保持原位置，保存配置记录其路径，迁移机器时需一起携带。glTF 依赖的纹理和 bin 文件需与模型一起保存，推荐单文件 `.glb`。

```ini
[appearance]
robot="hero"
team="red"
armor_model="/absolute/path/to/armor.glb"
armor_scale=1.0
```

`robot` 支持 infantry_3/infantry_4/infantry_5/hero/sentry。未明确写入的模块尺寸、受击宽高、半径和灯条间距继承该车型预设；明确配置的尺寸保持原值。界面切换兵种会更新预设尺寸和血量，并保留本轮统计。

- **装甲局部轴**：x 为正面视角的右方，y 向上，+z 是外法向。自动居中，按网格 x 宽归一化至 `target.module_width`，再乘 armor_scale。没有独立的模型安装偏移调节。
- 节点名包含 `Team` 或 `Lightbar`（忽略大小写）时，会被替换为当前阵营材质，并在血量归零后灭灯。其他表面保留模型材质。自定义装甲自行提供图案，内置装甲使用下列现成 PNG。
- `module_width/module_height` 表示整体外形；默认小装甲 140×125 mm、大装甲 235×127 mm。2026 制作规范图 3-16/3-17 的黑色面板宽为 135/230 mm，内置模型把侧灯计入总外宽。
- `lightbar_spacing/lightbar_length` 配置视觉灯条几何；`armor_width/armor_height/armor_tilt` 配置矩形命中近似。替换模型后应核对灯条、理想关键点及受击区域。
- 装甲沿前后左右对称安装，方向间隔 90°；对向中心距仍为 `2*target.radius`，界面的伸展滑条则显示包含板体、灯条、厚度和倾角的旋转外廓直径：默认 550 mm、项目上限 600 mm。半径会根据几何尺寸换算；相邻装甲保持间隙并处于彼此正面平面后方。高度滑条直接编辑基准下沿，默认 200 mm、高度差 -100 mm；换兵种保持下沿高度。见 README。
- 不执行模型附带的控制脚本，也不自动把自定义网格变成碰撞体。

## 保留的历史车体资源

`assets/models/{infantry,hero,sentry}.glb` 是先前下载的参考车体，当前不加载。它们来自 [rm-controls/rm_description](https://github.com/rm-controls/rm_description) 固定提交 `a4b31828bf964e491d3ba5a731d12c1213562feb`，作者 Qiayuan Liao / DynamicX，许可证 BSD-3-Clause。完整许可证和来源哈希保存在 `assets/third_party/rm_description/`，下载转换工具为 `tools/fetch_reference_models.py`。旧配置中的 `body_model/body_scale` 仍可读取，但不参与显示和碰撞。

## 装甲图案贴图

步兵 3/4/5、英雄 1、哨兵均使用 [LabelMaster 的实际参考图](https://github.com/tff345/label-robomaster/tree/b517820cc8591c056098b3ac808338b084b6eabd/pic)，固定提交 `b517820cc8591c056098b3ac808338b084b6eabd`，保留 MIT 许可证于 `assets/third_party/label_robomaster/LICENSE`。程序不使用字体或绘图代码生成编号。

| 本地 PNG | 上游文件 | 用途 |
|---|---|---|
| `infantry_3.png` | `pic/3.png` | 步兵 3 |
| `infantry_4.png` | `pic/4.png` | 步兵 4 |
| `infantry_5.png` | `pic/5.png` | 步兵 5 |
| `hero.png` | `pic/B1.png` | 英雄 1 |
| `sentry.png` | `pic/sb.png` | 哨兵炮塔标识 |

哨兵的预设编号仍为 7，内置装甲正面显示炮塔轮廓。图案保存在 `assets/stickers/sentry.png`，来自 [LabelMaster 的哨兵贴纸参考图](https://github.com/tff345/label-robomaster/blob/main/pic/sb.png)，并与 [官方 2026 制作规范 V1.2.0 第 104 页附录图 5](https://bbs-web-static.robomaster.com/a36873dca86c4883b9b067eda72ad43b1767087376172/RoboMaster%202026%20%E6%9C%BA%E7%94%B2%E5%A4%A7%E5%B8%88%E9%AB%98%E6%A0%A1%E7%B3%BB%E5%88%97%E8%B5%9B%E6%9C%BA%E5%99%A8%E4%BA%BA%E5%88%B6%E4%BD%9C%E8%A7%84%E8%8C%83%E6%89%8B%E5%86%8CV1.2.0%EF%BC%8820251230%EF%BC%89.pdf#page=104) 核对。

PNG 保留完整原图，渲染时使用 AtlasTexture 取中央图案，避开白色边缘和安装孔。面板底色从区域左上角的黑色像素采样，面板和贴图均不受光照影响，避免出现不同黑色的矩形边界。可在 `scripts/presets.gd` 各预设中替换 `sticker` 文件路径和 `sticker_region` 像素区域，区域左上角需为底色；红蓝切换只改变灯条，白色图案保持一致。自定义 GLB/glTF 装甲自行提供图案，不额外叠加内置贴图。素材固定版本、原图 SHA256、渲染区域和底色见 `assets/stickers/sources.json`。

## 网上找到的装甲资源

本轮检索还找到以下可供后续替换的来源：

- [hkustenterprize/RM2025-Portable-Armor](https://github.com/hkustenterprize/RM2025-Portable-Armor)：面向视觉调试的高仿真手持装甲，机械设计在 Mechanics，仓库采用 AGPL-3.0。
- [robomaster-oss/rmoss_gz_resources](https://github.com/robomaster-oss/rmoss_gz_resources)：包含大小装甲模块与编号贴纸。上游明确区分 SDF 代码与三维模型版权，不能把其 Apache-2.0 代码许可证直接视为所有模型的授权。

首版内置装甲采用本仓库生成的参数化几何，尚未复制上述两个仓库的装甲网格或贴纸。后续可以选择适合的机械版本，转换为 GLB 后直接替换。
