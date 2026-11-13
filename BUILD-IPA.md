# iPhone IPA — Build105 / V49 CPU

在 macOS / Xcode 26+、Python 3.12 执行 `bash Scripts/build-ipa.sh dist`。构建只校验配套文件、编译 App 与键盘并封装，不执行预测或测试。

模型来源为 V49 研究最佳 local1408/global94661，主干与双头一并打包，均固定 CPU。手机端两个编译模型及配套资源只在键盘扩展中保存一份，主 App 预览只读使用。

GitHub 构建从已验证测速构建 43366860373 取回精确的 Core ML 源包，SHA256 为 55142f2bb28776107fdf49c9ccb6f53f828f454a6238da1d824efdbaa4c8060e。本地同包保存在开发电脑 outputs/V49-Best-Model；历史 artifact 过期后，将该包放到 BuildAssets/V49/models.zip，或使用已还原且身份匹配的模型目录。

保留原 Bundle ID、App Groups 和签名安装方式。真机准确率、速度、内存及输入行为由用户验收。
