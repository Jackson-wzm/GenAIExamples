#!/bin/bash
# Copyright (C) 2024 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

set -xe

# 设置环境变量
'''
这里是使用了 := 运算符，它表示如果 IMAGE_REPO 已被设置且不为空，则使用其值；否则使用 OPEA_IMAGE_REPO 作为默认值
这样就确保了 IMAGE_REPO 总会有一个值，要么是预先设置好的 IMAGE_REPO，要么是 OPEA_IMAGE_REPO
'''
IMAGE_REPO=${IMAGE_REPO:-$OPEA_IMAGE_REPO}
# 类似地，这行代码表示如果 IMAGE_TAG 已被设置且不为空，则使用其值；否则默认使用 "latest" 作为镜像标签。
IMAGE_TAG=${IMAGE_TAG:-latest}

# 定义函数来处理 Docker 镜像名称的转换
function getImagenameFromMega() {
    echo $(echo "$1" | tr '[:upper:]' '[:lower:]')
    # 内层 echo "$1" 打印传递给函数的第一个参数
    # 管道 | 后的 tr '[:upper:]' '[:lower:]' 将字符串中的所有大写字母转换为小写字母。
    # 外层的 echo 再次打印转换后的结果。
    # 该函数的用途是确保镜像名称始终为小写，可能是为了与 Docker 镜像命名规范兼容
}


# 检查镜像是否存在， image 是之前先编译好的
function checkExist() {
    IMAGE_NAME=$1   #  函数的第一个参数中获取镜像名称，并将其赋值给变量 IMAGE_NAME
    if [ $(curl -X GET http://localhost:5000/v2/opea/${IMAGE_NAME}/tags/list | grep -c ${IMAGE_TAG}) -ne 0 ]; then
        # 使用 curl 发送一个 GET 请求到本地 Docker 镜像仓库的 REST API，获取特定镜像的标签列表。
        # 请求的 URL 中 opea 是仓库名称，${IMAGE_NAME} 是镜像名称
        grep -c ${IMAGE_TAG}:
            # 通过 grep 查找响应中是否包含指定的标签 ${IMAGE_TAG}，并返回匹配的次数。
            # if [ $(...) -ne 0 ]; then:
            # 检查匹配次数是否不等于 0。如果找到了匹配的标签，表示镜像存在。
            # echo "true" 和 echo "false":
            # 如果标签存在，函数输出 "true"；否则输出 "false"。
        echo "true"
    else
        echo "false"
    fi
}

function docker_build() {
    # check if if IMAGE_TAG is not "latest" and the image exists in the registry
    # 检查 images 是否存在
    if [ "$IMAGE_TAG" != "latest" ] && [ "$(checkExist $1)" == "true" ]; then
        echo "Image ${IMAGE_REPO}opea/$1:$IMAGE_TAG already exists in the registry"
        return
        '''
        说明该部分代码的作用是检查 IMAGE_TAG 是否不是 "latest"，以及镜像是否已经存在于注册表中。
        if [ "$IMAGE_TAG" != "latest" ] && [ "$(checkExist $1)" == "true" ]; then:
        "$IMAGE_TAG" != "latest": 检查镜像标签是否不是 "latest"。
        "$(checkExist $1)" == "true": 调用之前定义的 checkExist 函数，检查镜像是否已经存在。$1 是传递给 docker_build 的第一个参数，即镜像名称。
            如果上述两个条件都成立，意味着带有指定标签的镜像已经存在，代码将跳过构建过程。
        echo "Image ${IMAGE_REPO}opea/$1:$IMAGE_TAG already exists in the registry":
            输出一条消息，告知用户指定标签的镜像已经存在于镜像注册表中。
        return:
            退出函数，跳过镜像的构建和推送步骤。
        '''
    fi
    
    # 确定 Dockerfile 路径  docker_build 函数接受两个参数：服务名称和 Dockerfile 路径
    # docker_build <service_name> <dockerfile>
    if [ -z "$2" ]; then # 检查函数的第二个参数 $2 是否为空（即未提供 Dockerfile 路径）
        DOCKERFILE_PATH=Dockerfile #　如果未提供 Dockerfile 路径，默认使用当前目录下的 Dockerfile
    else
        DOCKERFILE_PATH=$2 # 如果提供了 Dockerfile 路径，将其赋值给 DOCKERFILE_PATH
    fi
    # 输出即将构建的镜像信息，包括镜像名称、标签和使用的 Dockerfile 路径
    echo "Building ${IMAGE_REPO}opea/$1:$IMAGE_TAG using Dockerfile $DOCKERFILE_PATH"

    # Docker build
    # if https_proxy and http_proxy are set, pass them to docker build
    if [ -z "$https_proxy" ]; then
        docker build --no-cache -t ${IMAGE_REPO}opea/$1:$IMAGE_TAG -f $DOCKERFILE_PATH .
    else
        docker build --no-cache -t ${IMAGE_REPO}opea/$1:$IMAGE_TAG --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy -f $DOCKERFILE_PATH .
    fi
    # 推送和删除 Docker 镜像
    docker push ${IMAGE_REPO}opea/$1:$IMAGE_TAG
    docker rmi ${IMAGE_REPO}opea/$1:$IMAGE_TAG
}

# $1 is like "apple orange pear"
# 用于处理不同的服务名称并根据服务名称构建相关的 Docker 镜像。它使用了之前定义的 docker_build 函数来构建镜像

# 循环遍历服务名称
for MEGA_SVC in $1; do  # 遍历传递给脚本的第一个参数（$1）。该参数可能是一个包含多个服务名称的字符串
    case $MEGA_SVC in   # 使用 case 语句根据 MEGA_SVC 的值执行不同的操作
        # 这一行列出了服务名称列表。如果 MEGA_SVC 匹配其中一个名称，则执行该分支的代码
        "ChatQnA"|"CodeGen"|"CodeTrans"|"DocSum"|"Translation"|"AudioQnA"|"SearchQnA"|"FaqGen")
            cd $MEGA_SVC/docker  # 进入每个子项目的  docker 文件夹中
            IMAGE_NAME="$(getImagenameFromMega $MEGA_SVC)"
            docker_build ${IMAGE_NAME}

            # 切换到 UI 目录并构建 UI 相关的镜像
            cd ui
            docker_build ${IMAGE_NAME}-ui docker/Dockerfile
            if [ "$MEGA_SVC" == "ChatQnA" ];then
                docker_build ${IMAGE_NAME}-conversation-ui docker/Dockerfile.react
            fi
            if [ "$MEGA_SVC" == "DocSum" ];then
                docker_build ${IMAGE_NAME}-react-ui docker/Dockerfile.react
            fi
            if [ "$MEGA_SVC" == "CodeGen" ];then
                docker_build ${IMAGE_NAME}-react-ui docker/Dockerfile.react
            fi
            ;;
        "VisualQnA")  # 目前还不支持
            echo "Not supported yet"
            ;;
        *)
            echo "Unknown function: $MEGA_SVC"
            ;;
    esac
done
