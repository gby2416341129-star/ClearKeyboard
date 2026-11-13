# Build106 / V49 CPU 输入修复

沿用 V49 local1408/global94661 的精确主干和双头，不训练、不重新转换权重。CPU-only保持不变。解码策略 build106-lexical-mixed-recall-1，候选64/池256，真实首音节字菜单保留原输入收据。

新增本地英文词表、确认键原样提交、Space中文选择、完整词组全拼/简拼记忆及数字前缀补全。继承App/键盘的Bundle ID、App Group与原用户记录，按epoch隔离清除。

执行 `bash Scripts/build-ipa.sh dist` 只做静态身份/哈希核对和Release编译封装，不执行模型或测试。Core ML源包来自已验证构建43366860373，SHA256 55142f2bb28776107fdf49c9ccb6f53f828f454a6238da1d824efdbaa4c8060e，artifact过期后可用本机原包放BuildAssets/V49/models.zip重建。

所有用户案例和真机速度/内存/准确率均待用户验收。
