## 关于此工程预设节点
- workstaion: 专门用来部署k8s集群
- master: K8S集群主节点
- node: K8S集群node节点

## 怎么利用此脚本
- 将本项目代码包下载到workstation节点/opt目录进行解压。
- 结合自身规划，替换k8s_setup.sh中以下变量
    ```
    WORKSTATION_HOST="10.0.0.240"
    WORKSTATION_ROOT_PASS=""
    #master IP list,at least 1
    K8S_MASTERS="10.0.0.241"
    MASTER_ROOT_PASS=""
    #node IP list,at least 3
    K8S_NODES="10.0.0.242,10.0.0.243,10.0.0.244"
    NODE_ROOT_PASS=""
    #pod cluster ip range
    POD_CLUSTER_IP="10.52.0.0/16"
    #service cluster ip range
    SERVICE_CLUSTER_IP="10.53.0.0/16"
    #kubernetes ip
    KUBERNETES_IP="10.53.0.1"
    #kubernetes dns ip
    KUBERNETES_DNS_IP="10.53.0.2"
    ```
- 运行脚本
    ```
    sh k8s_setup.sh
    ```