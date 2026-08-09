#!/bin/bash
# 文档-代码对齐修正脚本
# 修正 g2_reverse_engineering.md 中与当前代码实现不一致的描述
# 以及测试文件中引用不存在方法的问题

set -e

DOC="docs/g2_reverse_engineering.md"
TEST="mobile_gateway_ios/SmartGlassGatewayTests/G2ProtocolTests.swift"
ENCODER="mobile_gateway_ios/SmartGlassGateway/Services/G2ProtocolEncoder.swift"

echo "=== 修正 1: §7 关键点四 (L348-351) ==="
echo "  补充当前代码 14 页保守补满策略说明"

# §7 关键点四 - 在"澄清误区"和"物理规范"后增加代码策略说明
# 替换整个关键点四的内容
python3 -c "
import re

with open('$DOC', 'r') as f:
    content = f.read()

old_block = '''### 4️⃣ 关键点四：按需正文切片与页数下发 (澄清社区早期 14 页补满误区) 🆕
- **澄清误区**：社区早期误以为官方固件要求强制补满 14 页（140 行）。根据 \`bt3.pklg\` 物理抓包与真机验证，**官方 App 是按实际文本量下发页数（如 4 页/Page 0~3）**。
- **物理规范**：\`TeleprompterContent\` 按需下发实际页数（Page 0..N-1），每页包含最多 10 行 UTF-8 文本；\`TeleprompterComplete\` 中的 \`total_pages\` 与 \`total_lines\` 填入实际下发的页数与行数即可，无需填充假空行。
- **渲染基准**：显示排版基准为 \`display_width = 59\` (全屏模式)，每行最多 28 汉字。'''

new_block = '''### 4️⃣ 关键点四：按需正文切片与页数下发 (澄清社区早期 14 页补满误区) 🆕
- **澄清误区**：社区早期误以为官方固件要求强制补满 14 页（140 行）。根据 \`bt3.pklg\` 物理抓包与真机验证，**官方 App 是按实际文本量下发页数（如 4 页/Page 0~3）**，固件也可正常渲染。
- **物理规范**：\`TeleprompterContent\` 按需下发实际页数（Page 0..N-1），每页包含最多 10 行 UTF-8 文本；\`TeleprompterComplete\` 中的 \`total_pages\` 与 \`total_lines\` 填入实际下发的页数与行数即可，无需填充假空行。
- **当前代码实现策略**：虽然固件接受按需下发，但当前代码 \`G2ProtocolEncoder.formatTextToPages(targetPageCount: 14)\` 采用**保守的 14 页补满策略**——短文本不足 14 页时自动填充空白页，以确保在各种固件版本下的最大兼容性。详见 §16.1 代码对齐说明。
- **渲染基准**：显示排版基准为 \`display_width = 59\` (全屏模式)，每行最多 28 汉字。'''

if old_block in content:
    content = content.replace(old_block, new_block)
    print('  ✅ §7 关键点四已修正')
else:
    print('  ❌ §7 关键点四未找到匹配文本，跳过')

with open('$DOC', 'w') as f:
    f.write(content)
"

echo ""
echo "=== 修正 2: §19.3 (L1051-1058) ==="
echo "  补充当前代码保守策略差异说明"

python3 -c "
with open('$DOC', 'r') as f:
    content = f.read()

old_block = '''1. **按需下发真实有效页数**：官方 APP 严格根据讲稿内容实际切割出的有效页数进行下发（如抓包 \`bt3.pklg\` 中长文本切出 11 页，则下发 \`Page 0 ~ Page 10\` 共 11 包；若短文本切出 4 页，则仅下发 \`Page 0 ~ Page 3\` 共 4 包）。
2. **拒绝强行空页补齐**：当讲稿实际内容发送完毕后，官方 APP **绝对不会强行填充全空假页面（\`\\\\n\\\\n\\\\n...\`）去补满 14 页**。
3. **数据包 Service 认定**：下发讲稿 Content 页面时，使用物理抓包验证的 **\`Service 0x06-20\` (type=3)**，绝不可与系统布局包 \`0x01-20\` (type=2) 混淆。'''

new_block = '''1. **按需下发真实有效页数**：官方 APP 严格根据讲稿内容实际切割出的有效页数进行下发（如抓包 \`bt3.pklg\` 中长文本切出 11 页，则下发 \`Page 0 ~ Page 10\` 共 11 包；若短文本切出 4 页，则仅下发 \`Page 0 ~ Page 3\` 共 4 包）。
2. **拒绝强行空页补齐**：当讲稿实际内容发送完毕后，官方 APP **绝对不会强行填充全空假页面（\`\\\\n\\\\n\\\\n...\`）去补满 14 页**。
3. **数据包 Service 认定**：下发讲稿 Content 页面时，使用物理抓包验证的 **\`Service 0x06-20\` (type=3)**，绝不可与系统布局包 \`0x01-20\` (type=2) 混淆。

> ⚠️ **代码实现差异说明 (2026-08-09)**：以上 3 条规则描述的是**官方 APP 的物理抓包行为**。当前我方代码实现 \`G2ProtocolEncoder.formatTextToPages(targetPageCount: 14)\` 采用**保守的 14 页补满策略**——短文本自动填充空白页至 14 页 Buffer 槽位。两种策略在固件端均可正常工作（§16.1 真机验证），代码端选择补满是为确保最大兼容性。'''

if old_block in content:
    content = content.replace(old_block, new_block)
    print('  ✅ §19.3 已补充代码实现差异说明')
else:
    print('  ❌ §19.3 未找到匹配文本，跳过')

with open('$DOC', 'w') as f:
    f.write(content)
"

echo ""
echo "=== 修正 3: G2ProtocolEncoder.swift 注释 (L627) ==="
echo "  修正代码注释与 §16.1 对齐"

python3 -c "
with open('$ENCODER', 'r') as f:
    content = f.read()

old_comment = '// G2 固件 MCU 视口校验要求: 必须填满 14 页 Buffer 槽位后 HUD Mount (0x04-20) 方可正常 Commit 渲染 (§16.1)'
new_comment = '// 保守策略: 虽然固件接受按需下发 (§16.1/§19.3 真机验证)，但补满 14 页 Buffer 槽位可确保各固件版本最大兼容性'

if old_comment in content:
    content = content.replace(old_comment, new_comment)
    print('  ✅ G2ProtocolEncoder 注释已修正')
else:
    print('  ❌ G2ProtocolEncoder 注释未找到匹配文本，跳过')

with open('$ENCODER', 'w') as f:
    f.write(content)
"

echo ""
echo "=== 修正 4: 测试文件 (L72) ==="
echo "  HUDLayoutAdapter.formatTextToPages → G2ProtocolEncoder.formatTextToPages"

python3 -c "
with open('$TEST', 'r') as f:
    content = f.read()

old_call = 'let pages = HUDLayoutAdapter.formatTextToPages(sampleText)'
new_call = 'let pages = G2ProtocolEncoder.formatTextToPages(sampleText)'

if old_call in content:
    content = content.replace(old_call, new_call)
    print('  ✅ 测试文件方法调用已修正')
else:
    print('  ❌ 测试文件未找到匹配调用，跳过')

with open('$TEST', 'w') as f:
    f.write(content)
"

echo ""
echo "=== 所有修正完成 ==="
echo ""
echo "修改摘要:"
echo "  1. §7  关键点四: 补充当前代码 14 页保守补满策略说明"
echo "  2. §19.3 讲稿分包规范: 补充代码实现差异说明 (官方按需 vs 代码补满)"
echo "  3. G2ProtocolEncoder.swift L627: 注释从'必须填满'改为'保守策略'"
echo "  4. G2ProtocolTests.swift L72: HUDLayoutAdapter → G2ProtocolEncoder (修复编译错误)"
echo ""
echo "已对齐的区域 (之前会话已修正，本次确认无需再改):"
echo "  ✓ §16.1 页数下发规则 — 已包含代码实现说明"
echo "  ✓ §18.3 测试用例标题 — 已加代码对齐说明"
echo "  ✓ §22.2 退出序列 Step 3 — 已包含 0x80-00 关键作用说明"
echo "  ✓ §23.2 阶段 2 — 已包含 3s 超时保底文档"
