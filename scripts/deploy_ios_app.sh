#!/usr/bin/env bash
# =============================================================================
# SmartGlassGateway iOS App 一键编译、部署与启动脚本 (Release 模式)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../mobile_gateway_ios" && pwd)"

echo "🚀 [1/3] 正在查询已连接的 iPhone 设备..."
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
    echo "⌚️ 检测到已配对连接的物理 Apple Watch (ID: ${WATCH_ID})，正在直连部署 Watch App..."
    # 严格安装：绝不使用 || true 掩盖错误，安装失败必须立刻抛出！
    xcrun devicectl device install app --device "${WATCH_ID}" "${PROJECT_DIR}/build/Build/Products/Release-watchos/SmartGlassWatch.app"
    echo "✅ [手表安装校验通过] 新版本已确凿写入 Apple Watch 本地闪存！"
    
    echo "⚡️ 尝试唤醒 Apple Watch 上的前台进程 (终止旧进程并加载新二进制)..."
    xcrun devicectl device process launch --device "${WATCH_ID}" --terminate-existing edu.ncu.smartglass.gateway.watchkit || echo "⚠️ [提示] 若手表处于暗屏休眠状态，watchOS 安全机制会阻断命令行远程亮屏。新版本已安装，请在手表上解锁屏幕并点击 SmartGlassWatch 图标打开前台。"
else
    echo "ℹ️ 未检测到处于可用状态的物理 Apple Watch，Watch App 将通过 iPhone 蓝牙在后台自动同步。"
fi

echo "✅ 部署完成！"

