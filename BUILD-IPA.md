# Build107 / V49 CPU

模型仍为V49 local1408/global94661的同一主干和双头；CPU-only。当前解码策略 build107-structured-canonical-recall-1，8模型路径/32状态/64可见/256池预算保留，前缀与末端使用同一词格能量。

安装恢复使用私有容器连续性与owner/世代命名空间；新安装不读旧共享/Keychain镜像，覆盖升级依可信私有连续性保留。iOS没有卸载时执行App代码的钩子，此方案在下次启动读取数据前生效；不宽删其它App共享数据。

`bash Scripts/build-ipa.sh dist`仅做静态身份核对、Release编译和封装，不执行预测或测试。源Core ML包来自既有构建43366860373，SHA256 55142f2bb28776107fdf49c9ccb6f53f828f454a6238da1d824efdbaa4c8060e；历史artifact过期可使用本机原包BuildAssets/V49/models.zip。

研究报告与实测分开；本轮未量测准确率/速度/内存/删除重装效果，均由用户验收。
