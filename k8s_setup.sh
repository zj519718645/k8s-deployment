#!/bin/sh

#function: setup k8s cluster
#author: guoliang_gl_zhou
#date: 20200520

#=========define global varables=======
#dynamic variables
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

#========define global functions=======
FILE_TRANSFER() {
    target_path=${1}
    target_file=${2}
    echo ${target_file}:>>/srv/salt/scp.sls
    echo "  file.managed:">>/srv/salt/scp.sls
    echo "    - mode: 0755">>/srv/salt/scp.sls
    echo "    - name: ${target_path}/${target_file}">>/srv/salt/scp.sls
    echo "    - source: salt://${target_file}">>/srv/salt/scp.sls
}

#exit code
NETWORKFAILED=1
YUMINSTALLATIONFAILED=2
DOWNLOADFAILED=3
SALTCOMMANDFAILED=4
APISERVERFAILED=5
NODESJOINFAILED=6

#ftp server
FTPHOST="134.175.150.58"
FTPUSER="kdftp"
FTPPASS="kd123.com"

#software name
declare -A softwares_dic
softwares_dic=(
[CNI_NAME]="cni-plugins-linux-amd64-v0.8.2.tar.gz"
[ETCD_NAME]="etcd-v3.3.18-linux-amd64.tar.gz"
[K8SCLIENT_NAME]="kubernetes-client-linux-amd64.tar.gz"
[K8SNODE_NAME]="kubernetes-node-linux-amd64.tar.gz"
[K8SSERVER_NAME]="kubernetes-server-linux-amd64.tar.gz"
[FLANNEL_NAME]="flannel-v0.11.0-linux-amd64.tar.gz"
[CFSSL_NAME]="cfssl-R1.2-linux-amd64.tar.gz"
)
MD5_NAME="md5.txt"
INSTALLATION_SUBFOLDER="installation"
UPDATE_SUBFOLDER="update"

#apiserver token
ENCRYPTION_TOKEN=`head -c 32 /dev/urandom | base64`
BOOTSTRAP_TOKEN=`head -c 32 /dev/urandom | base64`

echo "======================================================"
echo "                   start deploying                    "
echo "======================================================"
echo ""
echo ""

#echo ${softwares_dic[CNI_NAME]}
#=========test network==================

echo "---------------------test network---------------------"
curl www.baidu.com >/dev/null
if [ $? -ne 0 ]
then
    echo "connect to internet failed"
    exit ${NETWORKFAILED}
fi
master_array=(${K8S_MASTERS//,/ })
nodes_array=(${K8S_NODES//,/ })
for master in ${master_array[@]}
do
    ping ${master} -c 1
    if [ $? -ne 0 ]
    then
        echo "connect to master failed"
        exit ${NETWORKFAILED}
    fi
done
for node in ${nodes_array[@]}
do
    ping ${node} -c 1
    if [ $? -ne 0 ]
    then
        echo "connect to node failed"
        exit ${NETWORKFAILED}
    fi
done


echo "----------------configure workstation-----------------"
#=========install lftp and salt-ssh==========
yum install -y lftp
lftp -version > /dev/null
if [ $? -ne 0 ]
then
    echo "lftp installed failed"
    exit ${YUMINSTALLATIONFAILED}
else
    echo "set ftp:passive off" >>/etc/lftp.conf
fi
yum -y install epel-release
yum install -y salt-ssh
salt-ssh --version > /dev/null
if [ $? -ne 0 ]
then
    echo "salt-ssh installed failed"
    exit ${YUMINSTALLATIONFAILED}
fi
mkdir -p /srv/salt
mkdir -p /var/log/salt


#=============download installation media===============
echo "--------------download installation medias------------"
#download software
lftp -c "open -u ${FTPUSER},${FTPPASS} ${FTPHOST}; get ${INSTALLATION_SUBFOLDER}/${MD5_NAME}"
for key in $(echo ${!softwares_dic[*]})
do
    lftp -c "open -u ${FTPUSER},${FTPPASS} ${FTPHOST}; get ${INSTALLATION_SUBFOLDER}/${softwares_dic[$key]}"
    grep `md5sum ${softwares_dic[$key]}` ${MD5_NAME}
    if [ $? -ne 0 ]
    then
        echo "download failed!"
        exit ${DOWNLOADFAILED}
    fi
    tar -xzf ${softwares_dic[$key]}
done

#config salt-ssh roster
if [ -f "/etc/salt/roster" ];then
    rm -f /etc/salt/roster
fi
#================prepare workstation================
for master in ${master_array[@]}
do
    echo "master-${master}:" >>/etc/salt/roster
    echo "  host: ${master}" >>/etc/salt/roster
    echo "  user: root" >>/etc/salt/roster
    echo "  passwd: ${MASTER_ROOT_PASS}" >>/etc/salt/roster
done
for node in ${nodes_array[@]}
do
    echo "node-${node}:" >>/etc/salt/roster
    echo "  host: ${node}" >>/etc/salt/roster
    echo "  user: root" >>/etc/salt/roster
    echo "  passwd: ${NODE_ROOT_PASS}" >>/etc/salt/roster
done

\cp kubernetes/client/bin/kubectl /usr/bin/
\cp cfssl/cfssl /usr/local/bin/
\cp cfssl/cfssl-certinfo /usr/local/bin/
\cp cfssl/cfssljson /usr/local/bin/
chmod +x /usr/local/bin/cfssl*

#================generate certificates==============
echo "---------------generate certificates------------------"
cd certs
#generate ca
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
#generate kubernetes cert
sed -i "s/{{K8S_MASTERS}}/${K8S_MASTERS}/g" kubernetes-csr.json
sed -i "s/{{KUBERNETES_IP}}/${KUBERNETES_IP}/g" kubernetes-csr.json
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kubernetes-csr.json | cfssljson -bare kubernetes
#generate admin cert
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes admin-csr.json | cfssljson -bare admin
#generate kube-proxy cert
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json  -profile=kubernetes  kube-proxy-csr.json | cfssljson -bare kube-proxy
#generate kube-controller-manager certs
sed -i "s/{{K8S_MASTERS}}/${K8S_MASTERS}/g" kube-controller-manager-csr.json
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
#generate kube-scheduler cert
sed -i "s/{{K8S_MASTERS}}/${K8S_MASTERS}/g" kube-scheduler-csr.json
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-scheduler-csr.json | cfssljson -bare kube-scheduler
#generate etcd cert
sed -i "s/{{K8S_MASTERS}}/${K8S_MASTERS}/g" etcd-csr.json
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes etcd-csr.json | cfssljson -bare etcd
#generate flannel cert
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes flanneld-csr.json | cfssljson -bare flanneld

#distribute certs
salt-ssh '*' -r 'mkdir -p /etc/kubernetes/ssl'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
#distribute certs to master
\cp etcd.pem /srv/salt/
\cp etcd-key.pem /srv/salt/
\cp ca.pem /srv/salt/
\cp ca-key.pem /srv/salt/
\cp admin.pem /srv/salt/
\cp admin-key.pem /srv/salt/
\cp kubernetes.pem /srv/salt/
\cp kubernetes-key.pem /srv/salt/
\cp kube-controller-manager.pem /srv/salt/
\cp kube-controller-manager-key.pem /srv/salt/
\cp kube-scheduler.pem /srv/salt/
\cp kube-scheduler-key.pem /srv/salt/
if [ -f "/srv/salt/scp.sls" ];then
    rm -rf /srv/salt/scp.sls
fi
FILE_TRANSFER "/etc/kubernetes/ssl" "ca.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "ca-key.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "etcd.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "etcd-key.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "admin.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "admin-key.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kubernetes.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kubernetes-key.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-controller-manager.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-controller-manager-key.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-scheduler.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-scheduler-key.pem"
salt-ssh 'master-*' state.sls scp
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi

#distribute certs to node
\cp flanneld.pem /srv/salt/
\cp flanneld-key.pem /srv/salt/
\cp kube-proxy.pem /srv/salt/
\cp kube-proxy-key.pem /srv/salt/
if [ -f "/srv/salt/scp.sls" ];then
    rm -rf /srv/salt/scp.sls
fi
FILE_TRANSFER "/etc/kubernetes/ssl" "ca.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "ca-key.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "flanneld.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "flanneld-key.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-proxy.pem"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-proxy-key.pem"
salt-ssh 'node-*' state.sls scp
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
cd ..

echo "---------------------install etcd---------------------"
salt-ssh 'master-*' -r 'mkdir -p /var/lib/etcd'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sed "s/{{K8S_MASTERS}}/${K8S_MASTERS}/g" etcd.service >/srv/salt/etcd.service
cd etcd
\cp etcdctl /srv/salt/
\cp etcd /srv/salt/
#construct scp.sls
if [ -f "/srv/salt/scp.sls" ];then
    rm -rf /srv/salt/scp.sls
fi
FILE_TRANSFER "/etc/systemd/system" "etcd.service"
FILE_TRANSFER "/usr/local/bin" "etcd"
FILE_TRANSFER "/usr/local/bin" "etcdctl"
salt-ssh 'master-*' state.sls scp
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
#start etcd daemon
salt-ssh 'master-*' -r 'systemctl daemon-reload && systemctl enable etcd.service && systemctl restart etcd.service'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s
cd ..


#======================install flannel and docker customize================
echo "--------------------install flannel-------------------"
sed "s/{{K8S_MASTERS}}/${K8S_MASTERS}/g" flannel.service >/srv/salt/flannel.service
\cp docker.service /srv/salt/
cd flannel
\cp flanneld /srv/salt/
\cp mk-docker-opts.sh /srv/salt/
if [ -f "/srv/salt/scp.sls" ];then
    rm -rf /srv/salt/scp.sls
fi
FILE_TRANSFER "/usr/local/bin" "flanneld"
FILE_TRANSFER "/usr/local/bin" "mk-docker-opts.sh"
FILE_TRANSFER "/etc/systemd/system" "flannel.service"
FILE_TRANSFER "/etc/systemd/system" "docker.service"
salt-ssh 'node-*' state.sls scp
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
#set network cluster in etcd

salt-ssh 'master-*' -r "etcdctl --ca-file=/etc/kubernetes/ssl/ca.pem --cert-file=/etc/kubernetes/ssl/etcd.pem --key-file=/etc/kubernetes/ssl/etcd-key.pem --endpoints=https://${K8S_MASTERS}:2379 mk /kubernetes/network/config '{\"Network\":\"${POD_CLUSTER_IP}\", \"SubnetLen\": 24, \"Backend\": {\"Type\": \"vxlan\"}}'"
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
#start flannel daemon
salt-ssh 'node-*' -r 'systemctl daemon-reload && systemctl enable flannel.service && systemctl restart flannel.service'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s
#start docker daemon
salt-ssh 'node-*' -r 'systemctl daemon-reload && systemctl enable docker.service && systemctl restart docker.service'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s
cd ..

#=========================install master===================
echo "--------------------install master--------------------"
\cp kubernetes/server/bin/kube-apiserver /srv/salt/
\cp kubernetes/server/bin/kubeadm /srv/salt/
\cp kubernetes/server/bin/kube-controller-manager /srv/salt/
\cp kubernetes/server/bin/kubectl /srv/salt/
\cp kubernetes/server/bin/kube-scheduler /srv/salt/

if [ -f "kubectl.kubeconfig" ];then
    rm kubectl.kubeconfig
fi
kubectl config set-cluster kubernetes --certificate-authority=certs/ca.pem --embed-certs=true --server=https://${K8S_MASTERS}:6443 --kubeconfig=kubectl.kubeconfig
kubectl config set-credentials admin --client-certificate=certs/admin.pem --client-key=certs/admin-key.pem --embed-certs=true --kubeconfig=kubectl.kubeconfig
kubectl config set-context kubernetes --cluster=kubernetes --user=admin --kubeconfig=kubectl.kubeconfig
mkdir -p /root/.kube
\cp kubectl.kubeconfig /root/.kube/config
\cp kubectl.kubeconfig /srv/salt/config
kubectl config use kubernetes
salt-ssh 'master-*' -r 'mkdir -p /root/.kube'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sed "s|{{ENCRYPTION_TOKEN}}|${ENCRYPTION_TOKEN}|g" encryption-config.yaml >/srv/salt/encryption-config.yaml
sed "s|{{BOOTSTRAP_TOKEN}}|${BOOTSTRAP_TOKEN}|g" bootstrap-token.csv >/srv/salt/bootstrap-token.csv
sed -e "s|{{K8S_MASTERS}}|${K8S_MASTERS}|g" -e "s|{{SERVICE_CLUSTER_IP}}|${SERVICE_CLUSTER_IP}|g" kube-apiserver.service >/srv/salt/kube-apiserver.service
salt-ssh 'master-*' -r 'mkdir -p /var/log/kubernetes'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi

if [ -f "kube-controller-manager.kubeconfig" ];then
    rm kube-controller-manager.kubeconfig
fi
sed "s|{{POD_CLUSTER_IP}}|${POD_CLUSTER_IP}|g" kube-controller-manager.service >/srv/salt/kube-controller-manager.service
kubectl config set-cluster kubernetes --certificate-authority=certs/ca.pem --embed-certs=true --server=https://${K8S_MASTERS}:6443 --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-credentials system:kube-controller-manager --client-certificate=certs/kube-controller-manager.pem --client-key=certs/kube-controller-manager-key.pem --embed-certs=true --kubeconfig=kube-controller-manager.kubeconfig
kubectl config set-context system:kube-controller-manager --cluster=kubernetes --user=system:kube-controller-manager --kubeconfig=kube-controller-manager.kubeconfig
kubectl config use-context system:kube-controller-manager --kubeconfig=kube-controller-manager.kubeconfig
\cp kube-controller-manager.kubeconfig /srv/salt/

if [ -f "kube-scheduler.kubeconfig" ];then
    rm kube-scheduler.kubeconfig
fi
sed -e "s/{{K8S_MASTERS}}/${K8S_MASTERS}/g" kube-scheduler.service  >/srv/salt/kube-scheduler.service
kubectl config set-cluster kubernetes --certificate-authority=certs/ca.pem --embed-certs=true --server=https://${K8S_MASTERS}:6443 --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-credentials system:kube-scheduler --client-certificate=certs/kube-scheduler.pem --client-key=certs/kube-scheduler-key.pem --embed-certs=true --kubeconfig=kube-scheduler.kubeconfig
kubectl config set-context system:kube-scheduler --cluster=kubernetes --user=system:kube-scheduler --kubeconfig=kube-scheduler.kubeconfig
kubectl config use-context system:kube-scheduler --kubeconfig=kube-scheduler.kubeconfig
\cp kube-scheduler.kubeconfig /srv/salt/

if [ -f "/srv/salt/scp.sls" ];then
    rm -rf /srv/salt/scp.sls
fi
FILE_TRANSFER "/usr/local/bin" "kube-apiserver"
FILE_TRANSFER "/usr/local/bin" "kubeadm"
FILE_TRANSFER "/usr/local/bin" "kube-controller-manager"
FILE_TRANSFER "/usr/local/bin" "kubectl"
FILE_TRANSFER "/root/.kube" "config"
FILE_TRANSFER "/usr/local/bin" "kube-scheduler"
FILE_TRANSFER "/etc/kubernetes/ssl" "encryption-config.yaml"
FILE_TRANSFER "/etc/kubernetes/ssl" "bootstrap-token.csv"
FILE_TRANSFER "/etc/systemd/system" "kube-apiserver.service"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-controller-manager.kubeconfig"
FILE_TRANSFER "/etc/systemd/system" "kube-controller-manager.service"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-scheduler.kubeconfig"
FILE_TRANSFER "/etc/systemd/system" "kube-scheduler.service"
salt-ssh 'master-*' state.sls scp
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
salt-ssh 'master-*' -r 'kubectl config use kubernetes'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
#launch apiserver
salt-ssh 'master-*' -r 'systemctl daemon-reload && systemctl enable kube-apiserver && systemctl restart kube-apiserver'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s
kubectl create clusterrolebinding kube-apiserver:kubelet-apis --clusterrole=system:kubelet-api-admin --user kubernetes
kubectl cluster-info
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${APISERVERFAILED}
fi
#launch controller manager
salt-ssh 'master-*' -r 'systemctl daemon-reload && systemctl enable kube-controller-manager && systemctl restart kube-controller-manager'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s
#launch scheduler
salt-ssh 'master-*' -r 'systemctl daemon-reload && systemctl enable kube-scheduler && systemctl restart kube-scheduler'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s


#=====================install nodes=========================
echo "--------------------install nodes---------------------"
salt-ssh 'node-*' -r 'mkdir -p /root/.kube && mkdir -p /var/log/kubernetes && mkdir -p /var/lib/kubelet && mkdir -p /var/lib/kube-proxy && mkdir -p /var/log/kubernetes/kube-proxy && mkdir -p /etc/cni/net.d'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi

#handle cni
\cp 10-default.conf /srv/salt/
\cp cni/bandwidth /srv/salt/
\cp cni/bridge /srv/salt/
\cp cni/dhcp /srv/salt/
\cp cni/firewall /srv/salt/
\cp cni/flannel /srv/salt/
\cp cni/host-device /srv/salt/
\cp cni/host-local /srv/salt/
\cp cni/ipvlan /srv/salt/
\cp cni/loopback /srv/salt/
\cp cni/macvlan /srv/salt/
\cp cni/portmap /srv/salt/
\cp cni/ptp /srv/salt/
\cp cni/sbr /srv/salt/
\cp cni/static /srv/salt/
\cp cni/tuning /srv/salt/
\cp cni/vlan /srv/salt/

\cp kubernetes/node/bin/kubectl /srv/salt/
\cp kubernetes/node/bin/kubelet /srv/salt/
\cp kubernetes/node/bin/kube-proxy /srv/salt/
if [ -f "bootstrap.kubeconfig" ];then
    rm bootstrap.kubeconfig
fi
kubectl config set-cluster kubernetes --certificate-authority=certs/ca.pem --embed-certs=true --server=https://${K8S_MASTERS}:6443 --kubeconfig=bootstrap.kubeconfig
kubectl config set-credentials kubelet-bootstrap --token=${BOOTSTRAP_TOKEN} --kubeconfig=bootstrap.kubeconfig
kubectl config set-context default --cluster=kubernetes --user=kubelet-bootstrap --kubeconfig=bootstrap.kubeconfig
kubectl config use-context default --kubeconfig=bootstrap.kubeconfig
kubectl create clusterrolebinding kubelet-bootstrap --clusterrole=system:node-bootstrapper --user=kubelet-bootstrap
\cp bootstrap.kubeconfig /srv/salt/
sed "s/{{KUBERNETES_DNS_IP}}/${KUBERNETES_DNS_IP}/g" kubelet.config.json >/srv/salt/kubelet.config.json


\cp kube-proxy.service >/srv/salt/kube-proxy.service
if [ -f "kube-proxy.kubeconfig" ];then
    rm kube-proxy.kubeconfig
fi
kubectl config set-cluster kubernetes --certificate-authority=certs/ca.pem --embed-certs=true --server=https://${K8S_MASTERS}:6443 --kubeconfig=kube-proxy.kubeconfig
kubectl config set-credentials kube-proxy --client-certificate=certs/kube-proxy.pem --client-key=certs/kube-proxy-key.pem --embed-certs=true --kubeconfig=kube-proxy.kubeconfig
kubectl config set-context default --cluster=kubernetes --user=kube-proxy --kubeconfig=kube-proxy.kubeconfig
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
\cp kube-proxy.kubeconfig /srv/salt/

if [ -f "/srv/salt/scp.sls" ];then
    rm -rf /srv/salt/scp.sls
fi
FILE_TRANSFER "/etc/cni/net.d" "10-default.conf"
FILE_TRANSFER "/usr/local/bin" "bandwidth"
FILE_TRANSFER "/usr/local/bin" "bridge"
FILE_TRANSFER "/usr/local/bin" "dhcp"
FILE_TRANSFER "/usr/local/bin" "firewall"
FILE_TRANSFER "/usr/local/bin" "flannel"
FILE_TRANSFER "/usr/local/bin" "host-device"
FILE_TRANSFER "/usr/local/bin" "host-local"
FILE_TRANSFER "/usr/local/bin" "ipvlan"
FILE_TRANSFER "/usr/local/bin" "loopback"
FILE_TRANSFER "/usr/local/bin" "macvlan"
FILE_TRANSFER "/usr/local/bin" "portmap"
FILE_TRANSFER "/usr/local/bin" "ptp"
FILE_TRANSFER "/usr/local/bin" "sbr"
FILE_TRANSFER "/usr/local/bin" "static"
FILE_TRANSFER "/usr/local/bin" "tuning"
FILE_TRANSFER "/usr/local/bin" "vlan"
FILE_TRANSFER "/usr/local/bin" "kubelet"
FILE_TRANSFER "/usr/local/bin" "kube-proxy"
FILE_TRANSFER "/usr/local/bin" "kubectl"
FILE_TRANSFER "/root/.kube" "config"
FILE_TRANSFER "/etc/kubernetes/ssl" "bootstrap.kubeconfig"
FILE_TRANSFER "/etc/kubernetes/ssl" "kubelet.config.json"
FILE_TRANSFER "/etc/systemd/system" "kube-proxy.service"
FILE_TRANSFER "/etc/kubernetes/ssl" "kube-proxy.kubeconfig"
salt-ssh 'node-*' state.sls scp
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi

for node in ${nodes_array[@]}
do
    sed "s/{{NODEIP}}/${node}/g" kubelet.service >/srv/salt/kubelet.service
    sed -e "s|{{NODEIP}}|${node}|g" -e "s|{{POD_CLUSTER_IP}}|${POD_CLUSTER_IP}|g" kube-proxy.config.yaml >/srv/salt/kube-proxy.config.yaml
    if [ -f "/srv/salt/scp.sls" ];then
        rm -rf /srv/salt/scp.sls
    fi
    FILE_TRANSFER "/etc/systemd/system" "kubelet.service"
    FILE_TRANSFER "/etc/kubernetes/ssl" "kube-proxy.config.yaml"
    salt-ssh "node-${node}" state.sls scp
    if [ $? -ne 0 ];then
        echo "above salt command execute failed on line ${LINENO}!"
        exit ${SALTCOMMANDFAILED}
    fi
done
#launch kubelet
salt-ssh 'node-*' -r 'systemctl daemon-reload && systemctl enable kubelet && systemctl restart kubelet'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s
#launch kube-proxy
salt-ssh 'node-*' -r 'systemctl daemon-reload && systemctl enable kube-proxy && systemctl restart kube-proxy'
if [ $? -ne 0 ];then
    echo "above salt command execute failed on line ${LINENO}!"
    exit ${SALTCOMMANDFAILED}
fi
sleep 5s

#accept csr
kubectl get csr|grep 'Pending' | awk 'NR>0{print $1}'| xargs kubectl certificate approve
kubectl get nodes
if [ $? -ne 0 ];then
    echo "nodes join failed!"
    exit ${NODESJOINFAILED}
fi

echo "#======================================================"
echo "               deploying succesfully                   "
echo "#======================================================"
