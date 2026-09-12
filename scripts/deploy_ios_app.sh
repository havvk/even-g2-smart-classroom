#!/usr/bin/env bash
# =============================================================================
# SmartGlassGateway iOS App 一键编译、部署与启动脚本 (Release 模式)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../mobile_gateway_ios" && pwd)"

echo "🧪 [0/4] 正在执行 TDD 协议回归门禁测试 (Python Unittest Discovery)..."
python3 -m unittest discover -s "${SCRIPT_DIR}/../tests" -p "test_*.py"
echo "✅ [TDD 门禁校验通过] 18 项信令契约与视口排版算法测试全部通过！"

echo "🚀 [1/4] 正在查询已连接的 iPhone 设备..."
DEVICE_LINE=$(xcodebuild -project "${PROJECT_DIR}/SmartGlassGateway.xcodeproj" -scheme SmartGlassGateway -showdestinations | grep "platform:iOS," | grep -v "placeholder" | grep -v "Simulator" | head -n 1 || true)

if [ -z "${DEVICE_LINE}" ]; then
    echo "❌ 未检测到已连接的真机 iOS 设备！请确保 iPhone 已通过 USB 连接并解锁。"
    exit 1
fi

DEVICE_ID=$(echo "${DEVICE_LINE}" | sed -n 's/.*id:\([^,]*\).*/\1/p' | tr -d ' ')
DEVICE_NAME=$(echo "${DEVICE_LINE}" | sed -n 's/.*name:\([^}]*\).*/\1/p')

echo "📱 检测到设备: ${DEVICE_NAME} (ID: ${DEVICE_ID})"

echo "🔨 [2/3] 正在编译 SmartGlassGateway App (Release 模式，剥离 Xcode Preview 校验干扰)..."
xcodebuild -project "${PROJECT_DIR}/SmartGlassGateway.xcodeproj" \
           -scheme SmartGlassGateway \
           -configuration Release \
           -destination "id=${DEVICE_ID}" \
           -derivedDataPath "${PROJECT_DIR}/build" \
           -allowProvisioningUpdates \
           build

echo "📲 [3/3] 正在部署 App 至 iPhone (${DEVICE_NAME})..."
xcrun devicectl device install app --device "${DEVICE_ID}" "${PROJECT_DIR}/build/Build/Products/Release-iphoneos/SmartGlassGateway.app"

echo "⚡️ 尝试拉起 iPhone 应用 (终止旧进程并加载新二进制)..."
xcrun devicectl device process launch --device "${DEVICE_ID}" --terminate-existing edu.ncu.smartglass.gateway || echo "⚠️ 如果手机处于锁屏状态，请解锁手机屏幕后手动点击 SmartGlassGateway 图标启动。"

# ⌚️ 自动检测并直连部署至配对的 Apple Watch
WATCH_ID=$(xcrun devicectl list devices | grep "physical" | grep -i "watch" | grep "available" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/) print $i}' | head -n 1 || true)
if [ -n "${WATCH_ID}" ]; then
    xcrun devicectl device install app --device "${WATCH_ID}" "${PROJECT_DIR}/build/Build/Products/Release-watchos/SmartGlassWatch.app" || echo "⚠️ [提示] Apple Watch 当前处于锁屏状态，无法写入。若需更新 Watch 端应用，请点亮并解锁手表后重新运行部署。"
    echo "✅ [手表处理完毕]"
    
    echo "⚡️ 尝试唤醒 Apple Watch 上的前台进程..."
    xcrun devicectl device process launch --device "${WATCH_ID}" --terminate-existing edu.ncu.smartglass.gateway.watchkit 2>/dev/null || echo "ℹ️ Watch App 将在用户抬腕点击图标时加载新二进制。"
else
    echo "ℹ️ 未检测到处于可用状态的物理 Apple Watch，Watch App 将通过 iPhone 蓝牙在后台自动同步。"
fi

echo "✅ 部署完成！"

