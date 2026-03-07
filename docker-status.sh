#!/bin/bash

# Recommend to set an alias

# Docker 容器管理脚本 - 表格形式 + 交互式管理
# 显示所有容器的名称、状态、健康检查和端口映射，并提供启动/暂停/停止功能

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 显示容器状态表格
show_containers() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}                              ${BOLD}Docker 容器状态总览${NC}                                        ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 获取所有容器（包括停止的）
    containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null)

    if [ -z "$containers" ]; then
        echo "没有容器"
        return 1
    fi

    # 打印表头
    printf "${BOLD}%-5s %-25s %-15s %-15s %-30s %-25s${NC}\n" "序号" "容器名称" "状态" "健康检查" "端口映射" "网络"
    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    # 遍历每个容器
    local index=1
    declare -g -a CONTAINER_NAMES=()

    for container in $containers; do
        CONTAINER_NAMES+=("$container")

        # 获取容器详细信息
        info=$(docker inspect "$container" 2>/dev/null)

        # 容器名称（截断过长的名称）
        name=$(printf "%.24s" "$container")

        # 运行状态
        status=$(echo "$info" | jq -r '.[0].State.Status')
        if [ "$status" = "running" ]; then
            status_text="✓ Running"
            status_color="${GREEN}"
        elif [ "$status" = "paused" ]; then
            status_text="⏸ Paused"
            status_color="${YELLOW}"
        elif [ "$status" = "exited" ]; then
            status_text="✗ Stopped"
            status_color="${RED}"
        else
            status_text="? $status"
            status_color="${CYAN}"
        fi

        # 健康检查
        health=$(echo "$info" | jq -r '.[0].State.Health.Status // "none"')
        if [ "$health" = "healthy" ]; then
            health_text="✓ Healthy"
            health_color="${GREEN}"
        elif [ "$health" = "unhealthy" ]; then
            health_text="✗ Unhealthy"
            health_color="${RED}"
        elif [ "$health" = "starting" ]; then
            health_text="⟳ Starting"
            health_color="${YELLOW}"
        else
            health_text="-"
            health_color="${CYAN}"
        fi

        # 端口映射（只显示主要端口）
        ports=$(docker port "$container" 2>/dev/null)
        if [ -n "$ports" ]; then
            # 提取第一个端口映射并格式化
            first_port=$(echo "$ports" | head -1 | sed 's/ -> /→/g' | sed 's/0.0.0.0://g' | sed 's/\[::\]://g')
            port_count=$(echo "$ports" | wc -l)
            if [ "$port_count" -gt 1 ]; then
                port_text=$(printf "%.25s +%d" "$first_port" $((port_count - 1)))
            else
                port_text=$(printf "%.29s" "$first_port")
            fi
        else
            port_text="-"
        fi

        # 网络信息（缩短显示）
        networks=$(echo "$info" | jq -r '.[0].NetworkSettings.Networks | keys | join(",")')
        network_text=$(printf "%.24s" "$networks")

        # 打印行
        printf "${BOLD}%-5s${NC} %-25s ${status_color}%-15s${NC} ${health_color}%-15s${NC} %-30s %-25s\n" \
            "$index" "$name" "$status_text" "$health_text" "$port_text" "$network_text"

        ((index++))
    done

    echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"

    # 统计信息
    total=$(docker ps -a -q | wc -l)
    running=$(docker ps --filter "status=running" -q | wc -l)
    paused=$(docker ps --filter "status=paused" -q | wc -l)
    stopped=$(docker ps --filter "status=exited" -q | wc -l)
    healthy=$(docker ps --filter "health=healthy" -q | wc -l)

    echo ""
    echo -e "${BOLD}统计:${NC} 总计 ${CYAN}${total}${NC} | 运行 ${GREEN}${running}${NC} | 暂停 ${YELLOW}${paused}${NC} | 停止 ${RED}${stopped}${NC} | 健康 ${GREEN}${healthy}${NC}"
    echo ""
}

# 获取容器的 compose 目录
get_compose_dir() {
    local container_name=$1
    local container_info=$(docker inspect "$container_name" 2>/dev/null)

    # 尝试从容器标签中获取项目路径
    local working_dir=$(echo "$container_info" | jq -r '.[0].Config.Labels."com.docker.compose.project.working_dir" // empty')

    if [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
        echo "$working_dir"
        return 0
    fi

    return 1
}

# 启动容器
start_container() {
    local container_name=$1
    echo -e "${YELLOW}正在启动容器: ${BOLD}$container_name${NC}"

    # 检查是否是 compose 项目
    compose_dir=$(get_compose_dir "$container_name")

    if [ -n "$compose_dir" ]; then
        echo -e "${CYAN}检测到 Docker Compose 项目，使用 compose 启动...${NC}"
        cd "$compose_dir"
        docker compose up -d "$container_name" 2>&1
    else
        docker start "$container_name" 2>&1
    fi

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 容器 $container_name 已启动${NC}"
    else
        echo -e "${RED}✗ 启动失败${NC}"
    fi
}

# 暂停容器
pause_container() {
    local container_name=$1
    echo -e "${YELLOW}正在暂停容器: ${BOLD}$container_name${NC}"
    docker pause "$container_name" 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 容器 $container_name 已暂停${NC}"
    else
        echo -e "${RED}✗ 暂停失败${NC}"
    fi
}

# 停止容器
stop_container() {
    local container_name=$1
    echo -e "${YELLOW}正在停止容器: ${BOLD}$container_name${NC}"
    docker stop "$container_name" 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 容器 $container_name 已停止${NC}"
    else
        echo -e "${RED}✗ 停止失败${NC}"
    fi
}

# 恢复暂停的容器
unpause_container() {
    local container_name=$1
    echo -e "${YELLOW}正在恢复容器: ${BOLD}$container_name${NC}"
    docker unpause "$container_name" 2>&1

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 容器 $container_name 已恢复${NC}"
    else
        echo -e "${RED}✗ 恢复失败${NC}"
    fi
}

# 主循环
main() {
    while true; do
        show_containers

        echo -e "${BOLD}${MAGENTA}请选择操作:${NC}"
        echo -e "  ${GREEN}1${NC} - 启动容器"
        echo -e "  ${YELLOW}2${NC} - 暂停容器"
        echo -e "  ${RED}3${NC} - 停止容器"
        echo -e "  ${CYAN}4${NC} - 恢复暂停的容器"
        echo -e "  ${BLUE}0${NC} - 刷新状态"
        echo -e "  ${RED}q${NC} - 退出"
        echo ""
        read -p "请输入选项 [0-4/q]: " action

        case $action in
            0)
                continue
                ;;
            q|Q)
                echo -e "${GREEN}再见!${NC}"
                exit 0
                ;;
            1|2|3|4)
                echo ""
                echo -e "${BOLD}${CYAN}请输入容器序号 (1-${#CONTAINER_NAMES[@]}) 或按 Enter 返回:${NC}"
                read -p "容器序号: " container_index

                # 如果用户按 Enter，返回主菜单
                if [ -z "$container_index" ]; then
                    continue
                fi

                # 验证输入
                if ! [[ "$container_index" =~ ^[0-9]+$ ]] || [ "$container_index" -lt 1 ] || [ "$container_index" -gt "${#CONTAINER_NAMES[@]}" ]; then
                    echo -e "${RED}无效的序号!${NC}"
                    sleep 2
                    continue
                fi

                # 获取容器名称
                container_name="${CONTAINER_NAMES[$((container_index - 1))]}"

                echo ""
                case $action in
                    1)
                        start_container "$container_name"
                        ;;
                    2)
                        pause_container "$container_name"
                        ;;
                    3)
                        stop_container "$container_name"
                        ;;
                    4)
                        unpause_container "$container_name"
                        ;;
                esac

                echo ""
                read -p "按 Enter 继续..."
                ;;
            *)
                echo -e "${RED}无效的选项!${NC}"
                sleep 1
                ;;
        esac
    done
}

# 运行主程序
main
