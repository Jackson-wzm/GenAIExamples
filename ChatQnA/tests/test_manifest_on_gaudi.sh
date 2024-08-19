#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -xe

# set -xe:
# -x: 启用调试模式。在执行每个命令之前，会打印命令及其参数。这对于调试脚本非常有用。
# -e: 启用错误模式。当脚本中的任何命令返回非零状态（即发生错误）时，脚本将立即退出。这可以防止脚本在发生错误后继续运行。
# 获取当前用户的用户名
USER_ID=$(whoami) # 使用 whoami 命令获取当前执行脚本的用户的用户名，并将其存储在 USER_ID 变量中。这个变量可以在脚本中用于引用当前用户。
# 设置日志目录路径
# 将日志目录路径设置为 /home/当前用户名/logs，并将其赋值给 LOG_PATH 变量。这意味着日志文件将存储在当前用户主目录下的 logs 子目录中
LOG_PATH=/home/$(whoami)/logs
# 设置 Hugging Face 缓存目录路径  设置 MOUNT_DIR 变量为 Hugging Face 缓存目录的路径，路径为 /home/当前用户名/.cache/huggingface/hub。这个目录通常用于存储模型文件的缓存
MOUNT_DIR=/home/$USER_ID/.cache/huggingface/hub
# 配置 Docker 镜像的仓库和标签
IMAGE_REPO=${IMAGE_REPO:-}
IMAGE_TAG=${IMAGE_TAG:-latest}

# 这段代码定义了一个名为 init_chatqna 的 Bash 函数，用于初始化 ChatQnA 服务的配置文件，
#特别是 Kubernetes 配置文件（.yaml 文件）。它通过替换文件中的特定占位符来配置服务的
#挂载目录、Docker 镜像标签和仓库信息，以及设置 Hugging Face 的访问令牌
#该函数封装了一组用于初始化 ChatQnA 服务的操作
function init_chatqna() {
    # replace the mount dir "path: /mnt/opea-models" with "path: $CHART_MOUNT"
    # find . -name '*.yaml' -type f：在当前目录及其子目录中查找所有扩展名为 .yaml 的文件。
    # -exec sed -i "s#path: /mnt/opea-models#path: $MOUNT_DIR#g" {}：对于找到的每个文件，使用 sed 命令进行替换。sed -i 选项表示直接修改文件。s#path: /mnt/opea-models#path: $MOUNT_DIR#g 指令将 path: /mnt/opea-models 替换为 path: $MOUNT_DIR，$MOUNT_DIR 是一个环境变量，包含新的挂载目录路径。
    # \;：这是 find 命令的语法，用于结束 -exec 操作。
    find . -name '*.yaml' -type f -exec sed -i "s#path: /mnt/opea-models#path: $MOUNT_DIR#g" {} \;
    # replace megaservice image tag  替换 MegaService 的 Docker 镜像标签
    find . -name '*.yaml' -type f -exec sed -i "s#image: opea/chatqna:latest#image: opea/chatqna:${IMAGE_TAG}#g" {} \;
    # replace the repository "image: opea/*" with "image: $IMAGE_REPO/opea/" 替换 Docker 镜像的仓库信息
    find . -name '*.yaml' -type f -exec sed -i "s#image: \"opea/*#image: \"${IMAGE_REPO}opea/#g" {} \;
    # set huggingface token 设置 Hugging Face 访问令牌
    find . -name '*.yaml' -type f -exec sed -i "s#insert-your-huggingface-token-here#$(cat /home/$USER_ID/.cache/huggingface/token)#g" {} \;
}

# 用于在 Kubernetes 中安装 ChatQnA 服务
function install_chatqna {
    # 打印命名空间信息 $NAMESPACE 是一个环境变量，通常由外部代码或脚本设置，表示 Kubernetes 中的命名空间名称
    echo "namespace is $NAMESPACE"
    # 应用 Kubernetes 配置
    # 使用 kubectl apply 命令将当前目录下的所有 Kubernetes 配置文件（通常是 YAML 文件）应用到指定的命名空间 ($NAMESPACE) 中。-f . 指定当前目录作为配置文件的来源，-n $NAMESPACE 指定应用到的命名空间。
    kubectl apply -f . -n $NAMESPACE
    # Sleep enough time for retreiver-usvc to be ready
    sleep 60
}

# 用于获取 Kubernetes 服务的 IP 地址和端口，并返回完整的服务访问端点
function get_end_point() {
    # $1 is service name, $2 is namespace
    # $1 表示服务的名称（service name） $2 表示命名空间（namespace），该服务所在的命名空间
    # 使用 kubectl get svc 命令来获取指定服务的详细信息 
    # $1 是服务名称  -n $2 指定命名空间 -o jsonpath='{.spec.clusterIP}' 通过 JSONPath 表达式提取服务的 clusterIP（集群内部 IP 地址）
    # 将提取到的 IP 地址存储在 ip_address 变量中
    ip_address=$(kubectl get svc $1 -n $2 -o jsonpath='{.spec.clusterIP}')

    # 获取服务的端口号
    port=$(kubectl get svc $1 -n $2 -o jsonpath='{.spec.ports[0].port}')
    # 使用与上面类似的命令来获取服务的端口号。
    # -o jsonpath='{.spec.ports[0].port}' 通过 JSONPath 表达式提取服务的第一个端口（ports[0].port）。
    # 将提取到的端口号存储在 port 变量中。
    echo "$ip_address:$port"
}

# 用于验证两个微服务是否准备就绪，并且能够正确响应请求
function validate_chatqna() {
    max_retry=20  # 设置最大重试次数
    # make sure microservice retriever-usvc is ready
    # try to curl retriever-svc for max_retry times

    # 生成随机测试嵌入向量
    # 使用 Python 生成一个包含 768 个随机数的列表，每个数在 -1 到 1 之间，作为测试用的嵌入向量（embedding）。
    # 模型降维
    #结果存储在 test_embedding 变量中，该变量将用于后续的请求。
    test_embedding=$(python3 -c "import random; embedding = [random.uniform(-1, 1) for _ in range(768)]; print(embedding)")

    # 第一个 微服务 chatqna-retriever-usvc  检索服务
    for ((i=1; i<=max_retry; i++))
    do
        # 获取服务端点并发送请求
        # 调用之前定义的 get_end_point 函数，获取 chatqna-retriever-usvc 服务在指定命名空间中的访问端点，并存储在 endpoint_url 变量中
        endpoint_url=$(get_end_point "chatqna-retriever-usvc" $NAMESPACE)

        # 使用 curl 命令向该服务发送一个 POST 请求：
        #-X POST 指定使用 POST 方法。
        #-d 选项后跟请求的 JSON 数据，该数据包括一个示例问题（“What is the revenue of Nike in 2023?”）和生成的测试嵌入向量。
        #-H 'Content-Type: application/json' 指定请求头为 Content-Type: application/json。
        #如果请求成功，&& break 将跳出循环，不再进行后续尝试。
        curl http://$endpoint_url/v1/retrieval -X POST \
            -d "{\"text\":\"What is the revenue of Nike in 2023?\",\"embedding\":${test_embedding}}" \
            -H 'Content-Type: application/json' && break
        # 等待一段时间再重试
        sleep 30 
    done
    # 检查重试次数是否超过最大值
    # if i is bigger than max_retry, then exit with error
    # 在循环结束后，检查是否已超过最大重试次数。
    # 如果超过，打印错误信息并退出脚本，返回状态码 1，表示验证失败
    if [ $i -gt $max_retry ]; then
        echo "Microservice retriever failed, exit with error."
        exit 1
    fi
    


    # 第二个微服务 microservice tgi-svc，结构跟上一个 微服务一样
    # make sure microservice tgi-svc is ready
    for ((i=1; i<=max_retry; i++))
    do
        endpoint_url=$(get_end_point "chatqna-tgi" $NAMESPACE)
        curl http://$endpoint_url/generate -X POST \
            -d '{"inputs":"What is Deep Learning?","parameters":{"max_new_tokens":17, "do_sample": true}}' \
            -H 'Content-Type: application/json' && break
        sleep 10
    done
    # if i is bigger than max_retry, then exit with error
    if [ $i -gt $max_retry ]; then
        echo "Microservice tgi failed, exit with error."
        exit 1
    fi

    # 第三个 功能检测
    # generate a random logfile name to avoid conflict among multiple runners
    # 定义日志文件路径
    # 定义 LOGFILE 变量，设置日志文件的路径为 $LOG_PATH/curlmega_$NAMESPACE.log。
    # $NAMESPACE 是命名空间的名称，用于区分不同的日志文件。
    LOGFILE=$LOG_PATH/curlmega_$NAMESPACE.log
    
    # 获取服务端点并发送请求
    # 调用 get_end_point 函数获取 chatqna 服务在指定命名空间中的访问端点，并将其存储在 endpoint_url 变量中。
    endpoint_url=$(get_end_point "chatqna" $NAMESPACE)

    #使用 curl 命令向 chatqna 服务发送一个 POST 请求：
    #http://$endpoint_url/v1/chatqna 是请求的目标 URL，/v1/chatqna 是服务的 API 端点。
    #-H "Content-Type: application/json" 指定请求头为 Content-Type: application/json。
    #-d '{"messages": "What is the revenue of Nike in 2023?"}' 是发送的 JSON 数据，
    # 其中包含一个问题 "What is the revenue of Nike in 2023?"。
    #> $LOGFILE 表示将 curl 命令的输出重定向到日志文件中。
    curl http://$endpoint_url/v1/chatqna -H "Content-Type: application/json" -d '{"messages": "What is the revenue of Nike in 2023?"}' > $LOGFILE
    
    # 使用 $? 获取上一个命令的退出码，并将其存储在 exit_code 变量中
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        # 如果 exit_code 不为 0，表示 curl 命令执行失败，打印错误信息，并退出脚本，返回状态码 1
        echo "Megaservice failed, please check the logs in $LOGFILE!"
        exit 1
    fi

    # 检查响应结果是否合理
    # 打印提示信息，表示正在检查响应结果的合理性。
    # 定义一个局部变量 status，初始值为 false。
    echo "Checking response results, make sure the output is reasonable. "
    local status=false
    if [[ -f $LOGFILE ]] &&
        # 使用 if 语句检查日志文件是否存在，并且文件中是否包含 "billion" 这个关键词,如果找到关键词，status 变量设置为 true
        [[ $(grep -c "billion" $LOGFILE) != 0 ]]; then
        status=true
    fi

    # 如果 status 变量仍然为 false，表示没有找到 "billion" 关键词，打印错误信息并退出脚本，返回状态码 1。
    # 如果 status 为 true，表示检查通过，打印成功信息
    if [ $status == false ]; then
        echo "Response check failed, please check the logs in artifacts!"
        exit 1
    else
        echo "Response check succeed!"
    fi
}

# 这段代码用于确保脚本在运行时至少有一个参数（函数名）被传递。如果没有传递参数，脚本会显示使用说明，并以状态码 1 退出，
# 表示执行失败。这是一种基本的错误处理机制，确保脚本不会在没有足够信息的情况下继续运行。
#  $# 是一个特殊变量，表示传递给脚本的参数个数。
#  这行代码检查参数个数是否为 0，即用户是否没有为脚本提供任何参数。
if [ $# -eq 0 ]; then 
    # echo 命令打印一条消息，告诉用户如何使用这个脚本。
    # Usage: $0 <function_name> 是使用说明，其中 $0 是另一个特殊变量，表示脚本的名称。
    # <function_name> 是用户应提供的参数，即要执行的函数的名称
    echo "Usage: $0 <function_name>"

    # exit 1 命令终止脚本的执行，并返回状态码 1。
    # 返回状态码 1 通常表示脚本因为某种错误或异常情况而退出。
    exit 1
fi

# 测试上面 三个  function
# 这段代码使用了 case 语句来根据传入的第一个参数 ($1) 执行不同的操作。case 语句是一种条件控制结构，用于在多个选项之间进行分支
case "$1" in  # "$1" 是传递给脚本的第一个参数，case 语句将根据它的值选择执行哪一段代码
    init_ChatQnA)
        # 将当前目录切换到 ChatQnA/kubernetes/manifests/gaudi，并将原目录压入目录栈中
        pushd ChatQnA/kubernetes/manifests/gaudi
        # 调用名为 init_chatqna 的函数，执行相关操作（可能是初始化 ChatQnA 服务的某些配置）
        init_chatqna

        # 从目录栈中弹出前一个目录，并切换回该目录，恢复到最初的工作目录
        popd
        ;;
    
    install_ChatQnA)
        pushd ChatQnA/kubernetes/manifests/gaudi
        NAMESPACE=$2    # 将传入的第二个参数 $2 赋值给 NAMESPACE 变量，用于指定 Kubernetes 命名空间
        install_chatqna # 调用名为 install_chatqna 的函数，执行安装 ChatQnA 服务的操作。
        popd
        ;;
    validate_ChatQnA)
        NAMESPACE=$2
        SERVICE_NAME=chatqna
        validate_chatqna
        ;;
    *)
        echo "Unknown function: $1"
        ;;
esac
