# 项目长期记忆

## 身份
- 产品名：**一账**（2026-11-24 由「一事」改名）
- 英文/工程名：`YiZhang`；Bundle ID：`com.xiaoban.yizhang`
- 工作空间：`~/Desktop/小半工作室/一账`
- 技术栈：SwiftUI + SwiftData + Swift Charts，iOS 17+，零第三方依赖

## 构建 / 测试
```
cd ~/Desktop/小半工作室/一账
xcodebuild -project YiZhang.xcodeproj -scheme YiZhang \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test \
  CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS=-disable-sandbox
```
- `OTHER_SWIFT_FLAGS=-disable-sandbox` 必带，否则 SwiftData 宏展开失败
- 模拟器 `iPhone 17 Pro`；截图 `xcrun simctl io booted screenshot`
- Debug 构建的业务代码在 `YiZhang.debug.dylib` 里，`strings`/`grep -a` 查符号必须查这个 dylib，且要带正对照

## 规矩
- 改名类批量替换禁止模糊匹配中文词，先列出精确形态再改（「同一事务」「一件事」「这一事实」都含「一事」子串）
