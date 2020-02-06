#!/bin/bash

set -euo pipefail

sh_ver="1.2.0"
SH_LINK="https://raw.githubusercontent.com/woniuzfb/iptv/master/iptv.sh"
SH_LINK_BACKUP="http://hbo.epub.fun/iptv.sh"
SH_FILE="/usr/local/bin/tv"
IPTV_ROOT="/usr/local/iptv"
FFMPEG_MIRROR_LINK="http://47.241.6.233/ffmpeg"
FFMPEG_MIRROR_ROOT="$IPTV_ROOT/ffmpeg"
LIVE_ROOT="$IPTV_ROOT/live"
CREATOR_LINK="https://raw.githubusercontent.com/bentasker/HLS-Stream-Creator/master/HLS-Stream-Creator.sh"
CREATOR_LINK_BACKUP="http://hbo.epub.fun/HLS-Stream-Creator.sh"
CREATOR_FILE="$IPTV_ROOT/HLS-Stream-Creator.sh"
JQ_FILE="$IPTV_ROOT/jq"
CHANNELS_FILE="$IPTV_ROOT/channels.json"
CHANNELS_TMP="$IPTV_ROOT/channels.tmp"
DEFAULT_DEMOS="http://hbo.epub.fun/default.json"
DEFAULT_CHANNELS_LINK="http://hbo.epub.fun/channels.json"
LOCK_FILE="$IPTV_ROOT/lock"
MONITOR_PID="$IPTV_ROOT/monitor.pid"
MONITOR_LOG="$IPTV_ROOT/monitor.log"
green="\033[32m"
red="\033[31m"
plain="\033[0m"
info="${green}[信息]$plain"
error="${red}[错误]$plain"
tip="${green}[注意]$plain"

[ $EUID -ne 0 ] && echo -e "[$error] 当前账号非ROOT(或没有ROOT权限),无法继续操作,请使用$green sudo su $plain来获取临时ROOT权限（执行后会提示输入当前账号的密码）." && exit 1

default='
{
    "seg_dir_name":"",
    "seg_length":6,
    "seg_count":5,
    "video_codec":"h264",
    "audio_codec":"aac",
    "video_audio_shift":"",
    "quality":"",
    "bitrates":"900-1280x720",
    "const":"no",
    "encrypt":"no",
    "input_flags":"-reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 2000 -timeout 2000000000 -y -nostats -nostdin -hide_banner -loglevel fatal",
    "output_flags":"-g 25 -sc_threshold 0 -sn -preset superfast -pix_fmt yuv420p -profile:v main",
    "sync_file":"",
    "sync_index":"data:0:channels",
    "sync_pairs":"chnl_name:channel_name,chnl_id:output_dir_name,chnl_pid:pid,chnl_cat=港澳台,url=http://xxx.com/live",
    "schedule_file":"",
    "version":"'"$sh_ver"'"
}'

SyncFile()
{
    case $action in
        "skip")
            action=""
            return
        ;;      
        "start"|"stop")
            GetDefault
        ;;
        "add")
            chnl_pid=$pid
            if [ -n "$($JQ_FILE '.channels[] | select(.pid=='"$chnl_pid"')' $CHANNELS_FILE)" ]
            then
                GetChannelInfo
            fi
        ;;
        *)
            echo -e "$error $action ???" && exit 1
        ;;
    esac

    new_pid=${new_pid:-""}
    d_sync_file=${d_sync_file:-""}
    d_sync_index=${d_sync_index:-""}
    d_sync_pairs=${d_sync_pairs:-""}
    if [ -n "$d_sync_file" ] && [ -n "$d_sync_index" ] && [ -n "$d_sync_pairs" ]
    then
        jq_index=""
        while IFS=':' read -ra index_arr
        do
            for a in "${index_arr[@]}"
            do
                case $a in
                    '') 
                        echo -e "$error sync设置错误..." && exit 1
                    ;;
                    *[!0-9]*)
                        jq_index="$jq_index.$a"
                    ;;
                    *) 
                        jq_index="${jq_index}[$a]"
                    ;;
                esac
            done
        done <<< "$d_sync_index"

        if [ "$action" == "stop" ]
        then
            if [ -n "$($JQ_FILE "$jq_index"'[]|select(.chnl_pid=="'"$chnl_pid"'")' "$d_sync_file")" ] 
            then
                $JQ_FILE "$jq_index"' -= ['"$jq_index"'[]|select(.chnl_pid=="'"$chnl_pid"'")]' "$d_sync_file" > "${d_sync_file}_tmp"
                mv "${d_sync_file}_tmp" "$d_sync_file"
            fi
        else
            jq_channel_add="[{"
            jq_channel_edit=""
            while IFS=',' read -ra index_arr
            do
                for b in "${index_arr[@]}"
                do
                    case $b in
                        '') 
                            echo -e "$error sync设置错误..." && exit 1
                        ;;
                        *) 
                            if [[ $b == *"="* ]] 
                            then
                                key=$(echo "$b" | cut -d= -f1)
                                value=$(echo "$b" | cut -d= -f2)
                                if [[ $value == *"http"* ]]  
                                then
                                    if [ -n "${kind:-}" ] 
                                    then
                                        if [ "$kind" == "flv" ] 
                                        then
                                            value=$chnl_flv_pull_link
                                        else
                                            value=""
                                        fi
                                    elif [ -z "${master:-}" ] || [ "$master" == 1 ]
                                    then
                                        value="$value/$chnl_output_dir_name/${chnl_playlist_name}_master.m3u8"
                                    else
                                        value="$value/$chnl_output_dir_name/${chnl_playlist_name}.m3u8"
                                    fi
                                fi
                                if [ -z "$jq_channel_edit" ] 
                                then
                                    jq_channel_edit="$jq_channel_edit(${jq_index}[]|select(.chnl_pid==\"$chnl_pid\")|.$key)=\"${value}\""
                                else
                                    jq_channel_edit="$jq_channel_edit|(${jq_index}[]|select(.chnl_pid==\"$chnl_pid\")|.$key)=\"${value}\""
                                fi
                            else
                                key=$(echo "$b" | cut -d: -f1)
                                value=$(echo "$b" | cut -d: -f2)
                                value="chnl_$value"

                                if [ "$value" == "chnl_pid" ] 
                                then
                                    if [ -n "$new_pid" ] 
                                    then
                                        value=$new_pid
                                    else
                                        value=${!value}
                                    fi
                                    key_last=$key
                                    value_last=$value
                                else 
                                    value=${!value}
                                    if [ -z "$jq_channel_edit" ] 
                                    then
                                        jq_channel_edit="$jq_channel_edit(${jq_index}[]|select(.chnl_pid==\"$chnl_pid\")|.$key)=\"${value}\""
                                    else
                                        jq_channel_edit="$jq_channel_edit|(${jq_index}[]|select(.chnl_pid==\"$chnl_pid\")|.$key)=\"${value}\""
                                    fi
                                fi
                            fi

                            if [ "$jq_channel_add" == "[{" ] 
                            then
                                jq_channel_add="$jq_channel_add\"$key\":\"${value}\""
                            else
                                jq_channel_add="$jq_channel_add,\"$key\":\"${value}\""
                            fi

                        ;;
                    esac
                done
            done <<< "$d_sync_pairs"
            [ -s "$d_sync_file" ] || printf '{"%s":0}' "ret" > "$d_sync_file"
            if [ "$action" == "add" ] || [ -z "$($JQ_FILE "$jq_index"'[]|select(.chnl_pid=="'"$chnl_pid"'")' "$d_sync_file")" ]
            then
                jq_channel_add="${jq_channel_add}}]"
                $JQ_FILE "$jq_index"' += '"$jq_channel_add"'' "$d_sync_file" > "${d_sync_file}_tmp"
                mv "${d_sync_file}_tmp" "$d_sync_file"
            else
                jq_channel_edit="$jq_channel_edit|(${jq_index}[]|select(.chnl_pid==\"$chnl_pid\")|.$key_last)=\"${value_last}\""
                $JQ_FILE "${jq_channel_edit}" "$d_sync_file" > "${d_sync_file}_tmp"
                mv "${d_sync_file}_tmp" "$d_sync_file"
            fi
        fi
        echo -e "$info sync 执行成功..."
    fi
    action=""
}

CheckRelease()
{
    if grep -Eqi "(Red Hat|CentOS|Fedora|Amazon)" < /etc/issue
    then
        release="rpm"
    elif grep -Eqi "Debian" < /etc/issue
    then
        release="deb"
    elif grep -Eqi "Ubuntu" < /etc/issue
    then
        release="ubu"
    else
        if grep -Eqi "(redhat|centos|Red\ Hat)" < /proc/version
        then
            release="rpm"
        elif grep -Eqi "debian" < /proc/version
        then
            release="deb"
        elif grep -Eqi "ubuntu" < /proc/version
        then
            release="ubu"
        fi
    fi

    if [ "$(uname -m | grep -c 64)" -gt 0 ]
    then
        release_bit="64"
    else
        release_bit="32"
    fi

    update_once=0
    depends=(unzip vim curl cron crond)
    
    for depend in "${depends[@]}"; do
        DEPEND_FILE="$(command -v "$depend" || true)"
        if [ -z "$DEPEND_FILE" ]
        then
            case "$release" in
                "rpm")
                    if [ "$depend" != "cron" ]
                    then
                        if [ $update_once == 0 ]
                        then
                            yum -y update >/dev/null 2>&1
                            update_once=1
                        fi
                        if yum -y install "$depend" >/dev/null 2>&1
                        then
                            echo -e "$info 依赖 $depend 安装成功..."
                        else
                            echo -e "$error 依赖 $depend 安装失败..." && exit 1
                        fi
                    fi
                ;;
                "deb"|"ubu")
                    if [ "$depend" != "crond" ]
                    then
                        if [ $update_once == 0 ]
                        then
                            apt-get -y update >/dev/null 2>&1
                            update_once=1
                        fi
                        if apt-get -y install "$depend" >/dev/null 2>&1
                        then
                            echo -e "$info 依赖 $depend 安装成功..."
                        else
                            echo -e "$error 依赖 $depend 安装失败..." && exit 1
                        fi
                    fi
                ;;
                *) echo -e "\n系统不支持!" && exit 1
                ;;
            esac
            
        fi
    done
}

InstallFfmpeg()
{
    FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
    FFMPEG="$FFMPEG_ROOT/ffmpeg"
    if [ ! -e "$FFMPEG" ]
    then
        echo -e "$info 开始下载/安装 FFmpeg..."
        if [ "$release_bit" == "64" ]
        then
            ffmpeg_package="ffmpeg-git-amd64-static.tar.xz"
        else
            ffmpeg_package="ffmpeg-git-i686-static.tar.xz"
        fi
        FFMPEG_PACKAGE_FILE="$IPTV_ROOT/$ffmpeg_package"
        wget --no-check-certificate "$FFMPEG_MIRROR_LINK/builds/$ffmpeg_package" --show-progress -qO "$FFMPEG_PACKAGE_FILE"
        [ ! -e "$FFMPEG_PACKAGE_FILE" ] && echo -e "$error ffmpeg压缩包 下载失败 !" && exit 1
        tar -xJf "$FFMPEG_PACKAGE_FILE" -C "$IPTV_ROOT" && rm -rf "${FFMPEG_PACKAGE_FILE:-'notfound'}"
        FFMPEG=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
        [ ! -e "$FFMPEG" ] && echo -e "$error ffmpeg压缩包 解压失败 !" && exit 1
        export FFMPEG
        echo -e "$info FFmpeg 安装完成..."
    else
        echo -e "$info FFmpeg 已安装..."
    fi
}

InstallJq()
{
    if [ ! -e "$JQ_FILE" ]
    then
        echo -e "$info 开始下载/安装 JSNO解析器 JQ..."
        #experimental# grep -Po '"tag_name": "jq-\K.*?(?=")'
        jq_ver=$(curl --silent -m 10 "https://api.github.com/repos/stedolan/jq/releases/latest" |  grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)
        if [ -n "$jq_ver" ]
        then
            wget --no-check-certificate "https://github.com/stedolan/jq/releases/download/$jq_ver/jq-linux$release_bit" --show-progress -qO "$JQ_FILE"
        fi
        [ ! -e "$JQ_FILE" ] && echo -e "$error 下载JQ解析器失败，请检查 !" && exit 1
        chmod +x "$JQ_FILE"
        echo -e "$info JQ解析器 安装完成..." 
    else
        echo -e "$info JQ解析器 已安装..."
    fi
}

Install()
{
    echo -e "$info 检查依赖..."
    CheckRelease
    if [ -e "$IPTV_ROOT" ]
    then
        echo -e "$error 目录已存在，请先卸载..." && exit 1
    else
        mkdir -p "$IPTV_ROOT"
        echo -e "$info 下载脚本..."
        wget --no-check-certificate "$CREATOR_LINK" -qO "$CREATOR_FILE" && chmod +x "$CREATOR_FILE"
        if [ ! -s "$CREATOR_FILE" ] 
        then
            echo -e "$error 无法连接到 Github ! 尝试备用链接..."
            wget --no-check-certificate "$CREATOR_LINK_BACKUP" -qO "$CREATOR_FILE" && chmod +x "$CREATOR_FILE"
            if [ ! -s "$CREATOR_FILE" ] 
            then
                echo -e "$error 无法连接备用链接!"
                rm -rf "${IPTV_ROOT:-'notfound'}"
                exit 1
            fi
        fi
        echo -e "$info 脚本就绪..."
        InstallFfmpeg
        InstallJq
        printf "[]" > "$CHANNELS_FILE"
        default='
{
    "default":'"$default"',
    "channels":[]
}'
        $JQ_FILE '(.)='"$default"'' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        echo -e "$info 安装完成..."
    fi
}

Uninstall()
{
    [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
    CheckRelease
    echo "确定要 卸载此脚本以及产生的全部文件？[y/N]" && echo
    read -p "(默认: N):" uninstall_yn
    uninstall_yn=${uninstall_yn:-"N"}
    if [[ "$uninstall_yn" == [Yy] ]]
    then
        MonitorStop
        while IFS= read -r chnl_pid
        do
            chnl_status=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').status' "$CHANNELS_FILE")
            if [ "${kind:-}" == "flv" ] 
            then
                if [ "$chnl_flv_status" == "on" ] 
                then
                    StopChannel
                fi
            elif [ "$chnl_status" == "on" ]
            then
                StopChannel
            fi
        done <<< $($JQ_FILE '.channels[].pid' $CHANNELS_FILE)
        rm -rf "${IPTV_ROOT:-'notfound'}"
        echo && echo -e "$info 卸载完成 !" && echo
    else
        echo && echo -e "$info 卸载已取消..." && echo
    fi
}

Update()
{
    CheckRelease
    rm -rf "$IPTV_ROOT"/ffmpeg-git-*/
    echo -e "$info 更新 FFmpeg..."
    InstallFfmpeg
    rm -rf "${JQ_FILE:-'notfound'}"
    echo -e "$info 更新 JQ..."
    InstallJq
    echo -e "$info 更新 iptv 脚本..."
    sh_new_ver=$(wget --no-check-certificate -qO- -t1 -T3 "$SH_LINK"|grep 'sh_ver="'|awk -F "=" '{print $NF}'|sed 's/\"//g'|head -1 || true)
    if [ -z "$sh_new_ver" ] 
    then
        echo -e "$error 无法连接到 Github ! 尝试备用链接..."
        sh_new_ver=$(wget --no-check-certificate -qO- -t1 -T3 "$SH_LINK_BACKUP"|grep 'sh_ver="'|awk -F "=" '{print $NF}'|sed 's/\"//g'|head -1 || true)
        [ -z "$sh_new_ver" ] && echo -e "$error 无法连接备用链接!" && exit 1
    fi

    if [ "$sh_new_ver" != "$sh_ver" ] 
    then
        rm -rf "${LOCK_FILE:-'notfound'}"
    fi
    wget --no-check-certificate "$SH_LINK" -qO "$SH_FILE" && chmod +x "$SH_FILE"
    if [ ! -s "$SH_FILE" ] 
    then
        wget --no-check-certificate "$SH_LINK_BACKUP" -qO "$SH_FILE"
        if [ ! -s "$SH_FILE" ] 
        then
            echo -e "$error 无法连接备用链接!"
            exit 1
        fi
    fi

    rm -rf ${CREATOR_FILE:-'notfound'}
    echo -e "$info 更新 Hls Stream Creator 脚本..."
    wget --no-check-certificate "$CREATOR_LINK" -qO "$CREATOR_FILE" && chmod +x "$CREATOR_FILE"
    if [ ! -s "$CREATOR_FILE" ] 
    then
        echo -e "$error 无法连接到 Github ! 尝试备用链接..."
        wget --no-check-certificate "$CREATOR_LINK_BACKUP" -qO "$CREATOR_FILE" && chmod +x "$CREATOR_FILE"
        if [ ! -s "$CREATOR_FILE" ] 
        then
            echo -e "$error 无法连接备用链接!"
            exit 1
        fi
    fi

    echo -e "脚本已更新为最新版本[ $sh_new_ver ] !(输入: tv 使用)" && exit 0
}

UpdateSelf()
{
    sh_old_ver=$($JQ_FILE '.default.version' $CHANNELS_FILE)
    if [ "$sh_old_ver" != "$sh_ver" ] 
    then
        echo -e "$info 更新中，请稍等..."
        default_seg_dir_name=$($JQ_FILE -r '.default.seg_dir_name' "$CHANNELS_FILE")
        default_seg_length=$($JQ_FILE -r '.default.seg_length' "$CHANNELS_FILE")
        default_seg_count=$($JQ_FILE -r '.default.seg_count' "$CHANNELS_FILE")
        default_video_codec=$($JQ_FILE -r '.default.video_codec' "$CHANNELS_FILE")
        default_audio_codec=$($JQ_FILE -r '.default.audio_codec' "$CHANNELS_FILE")
        default_video_audio_shift=$($JQ_FILE -r '.default.video_audio_shift' "$CHANNELS_FILE")
        [ "$default_video_audio_shift" == null ] && default_video_audio_shift=""
        default_quality=$($JQ_FILE -r '.default.quality' "$CHANNELS_FILE")
        default_bitrates=$($JQ_FILE -r '.default.bitrates' "$CHANNELS_FILE")
        default_const=$($JQ_FILE -r '.default.const' "$CHANNELS_FILE")
        default_encrypt=$($JQ_FILE -r '.default.encrypt' "$CHANNELS_FILE")
        default_input_flags=$($JQ_FILE -r '.default.input_flags' "$CHANNELS_FILE")
        default_output_flags=$($JQ_FILE -r '.default.output_flags' "$CHANNELS_FILE")
        default_sync_file=$($JQ_FILE -r '.default.sync_file' "$CHANNELS_FILE")
        default_sync_index=$($JQ_FILE -r '.default.sync_index' "$CHANNELS_FILE")
        default_sync_pairs=$($JQ_FILE -r '.default.sync_pairs' "$CHANNELS_FILE")
        default_schedule_file=$($JQ_FILE -r '.default.schedule_file' "$CHANNELS_FILE")
        default=$($JQ_FILE '(.seg_dir_name)="'"$default_seg_dir_name"'"|(.seg_length)='"$default_seg_length"'|(.seg_count)='"$default_seg_count"'|(.video_codec)="'"$default_video_codec"'"|(.audio_codec)="'"$default_audio_codec"'"|(.video_audio_shift)="'"$default_video_audio_shift"'"|(.quality)="'"$default_quality"'"|(.bitrates)="'"$default_bitrates"'"|(.const)="'"$default_const"'"|(.encrypt)="'"$default_encrypt"'"|(.input_flags)="'"$default_input_flags"'"|(.output_flags)="'"$default_output_flags"'"|(.sync_file)="'"$default_sync_file"'"|(.sync_index)="'"$default_sync_index"'"|(.sync_pairs)="'"$default_sync_pairs"'"|(.schedule_file)="'"$default_schedule_file"'"' <<< "$default")

        $JQ_FILE '. + {default: '"$default"'}' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"

        while IFS= read -r chnl_pid
        do
            [ -z "$chnl_pid" ] && break
            chnl_status=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').status' "$CHANNELS_FILE")
            chnl_stream_link=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').stream_link' "$CHANNELS_FILE")
            chnl_output_dir_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').output_dir_name' "$CHANNELS_FILE")
            chnl_playlist_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').playlist_name' "$CHANNELS_FILE")
            chnl_seg_dir_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').seg_dir_name' "$CHANNELS_FILE")
            chnl_seg_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').seg_name' "$CHANNELS_FILE")
            chnl_seg_length=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').seg_length' "$CHANNELS_FILE")
            chnl_seg_count=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').seg_count' "$CHANNELS_FILE")
            chnl_video_codec=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').video_codec' "$CHANNELS_FILE")
            chnl_audio_codec=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').audio_codec' "$CHANNELS_FILE")
            chnl_video_audio_shift=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').video_audio_shift' "$CHANNELS_FILE")
            chnl_quality=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').quality' "$CHANNELS_FILE")
            chnl_bitrates=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').bitrates' "$CHANNELS_FILE")
            chnl_const=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').const' "$CHANNELS_FILE")
            chnl_encrypt=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').encrypt' "$CHANNELS_FILE")
            chnl_key_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').key_name' "$CHANNELS_FILE")
            chnl_input_flags=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').input_flags' "$CHANNELS_FILE")
            chnl_output_flags=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').output_flags' "$CHANNELS_FILE")
            chnl_channel_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').channel_name' "$CHANNELS_FILE")
            chnl_flv_status=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').flv_status' "$CHANNELS_FILE")
            chnl_flv_push_link=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').flv_push_link' "$CHANNELS_FILE")
            chnl_flv_pull_link=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').flv_pull_link' "$CHANNELS_FILE")

            $JQ_FILE '.channels -= [.channels[]|select(.pid=='"$chnl_pid"')]' "$CHANNELS_FILE" > "$CHANNELS_TMP"
            mv "$CHANNELS_TMP" "$CHANNELS_FILE"

            [ "$chnl_video_audio_shift" == null ] && chnl_video_audio_shift=$default_video_audio_shift
            [ "$chnl_flv_status" == null ] && chnl_flv_status="off"
            [ "$chnl_flv_push_link" == null ] && chnl_flv_push_link=""
            [ "$chnl_flv_pull_link" == null ] && chnl_flv_pull_link=""

            if [ "$chnl_const" == "yes" ]
            then
                chnl_const_yn="yes"
            else
                chnl_const_yn="no"
            fi
            if [ "$chnl_encrypt" == "yes" ]
            then
                chnl_encrypt_yn="yes"
            else
                chnl_encrypt_yn="no"
            fi
            $JQ_FILE '.channels += [
                {
                    "pid":'"$chnl_pid"',
                    "status":"'"$chnl_status"'",
                    "stream_link":"'"$chnl_stream_link"'",
                    "output_dir_name":"'"$chnl_output_dir_name"'",
                    "playlist_name":"'"$chnl_playlist_name"'",
                    "seg_dir_name":"'"$chnl_seg_dir_name"'",
                    "seg_name":"'"$chnl_seg_name"'",
                    "seg_length":'"$chnl_seg_length"',
                    "seg_count":'"$chnl_seg_count"',
                    "video_codec":"'"$chnl_video_codec"'",
                    "audio_codec":"'"$chnl_audio_codec"'",
                    "video_audio_shift":"'"$chnl_video_audio_shift"'",
                    "quality":"'"$chnl_quality"'",
                    "bitrates":"'"$chnl_bitrates"'",
                    "const":"'"$chnl_const_yn"'",
                    "encrypt":"'"$chnl_encrypt_yn"'",
                    "key_name":"'"$chnl_key_name"'",
                    "input_flags":"'"$chnl_input_flags"'",
                    "output_flags":"'"$chnl_output_flags"'",
                    "channel_name":"'"$chnl_channel_name"'",
                    "flv_status":"off",
                    "flv_push_link":"'"$chnl_flv_push_link"'",
                    "flv_pull_link":"'"$chnl_flv_pull_link"'"
                }
            ]' "$CHANNELS_FILE" > "$CHANNELS_TMP"
            mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        done <<< $($JQ_FILE '.channels[].pid' $CHANNELS_FILE)
        
    fi
    printf "" > ${LOCK_FILE}
}

GetDefault()
{
    default_array=()
    while IFS='' read -r default_line
    do
        default_array+=("$default_line");
    done < <($JQ_FILE -r '.default[] | @sh' "$CHANNELS_FILE")
    d_seg_dir_name=${default_array[0]//\'/}
    d_seg_dir_name_text=${d_seg_dir_name:-"不使用"}
    d_seg_length=${default_array[1]//\'/}
    d_seg_count=${default_array[2]//\'/}
    d_video_codec=${default_array[3]//\'/}
    d_audio_codec=${default_array[4]//\'/}
    d_video_audio_shift=${default_array[5]//\'/}

    v_or_a=${d_video_audio_shift%_*}
    if [ "$v_or_a" == "v" ] 
    then
        d_video_shift=${d_video_audio_shift#*_}
        d_video_audio_shift_text="画面延迟 $d_video_shift 秒"
    elif [ "$v_or_a" == "a" ] 
    then
        d_audio_shift=${d_video_audio_shift#*_}
        d_video_audio_shift_text="声音延迟 $d_audio_shift 秒"
    else
        d_video_audio_shift_text="不设置"
    fi

    d_quality=${default_array[6]//\'/}
    d_quality_text=${d_quality:-"不设置"}
    d_bitrates=${default_array[7]//\'/}
    d_const_yn=${default_array[8]//\'/}
    if [ "$d_const_yn" == "no" ] 
    then
        d_const_yn="N"
        d_const=""
    else
        d_const_yn="Y"
        d_const="-C"
    fi
    d_encrypt_yn=${default_array[9]//\'/}
    if [ "$d_encrypt_yn" == "no" ] 
    then
        d_encrypt_yn="N"
        d_encrypt=""
    else
        d_encrypt_yn="Y"
        d_encrypt="-e"
    fi
    d_input_flags=${default_array[10]//\'/}
    d_output_flags=${default_array[11]//\'/}
    d_sync_file=${default_array[12]//\'/}
    d_sync_index=${default_array[13]//\'/}
    d_sync_pairs=${default_array[14]//\'/}
    d_schedule_file=${default_array[15]//\'/}
}

GetChannelsInfo()
{
    [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1

    channels_count=0
    chnls_pid=()
    chnls_status=()
    chnls_output_dir_name=()
    chnls_playlist_name=()
    chnls_video_codec=()
    chnls_audio_codec=()
    chnls_video_audio_shift=()
    chnls_quality=()
    chnls_bitrates=()
    chnls_const=()
    chnls_channel_name=()
    chnls_flv_status=()
    chnls_flv_push_link=()
    chnls_flv_pull_link=()
    
    while IFS= read -r channel
    do
        channels_count=$((channels_count+1))
        map_pid=${channel#*pid: }
        map_pid=${map_pid%, status:*}
        map_status=${channel#*status: }
        map_status=${map_status%, output_dir_name:*}
        map_output_dir_name=${channel#*output_dir_name: }
        map_output_dir_name=${map_output_dir_name%, playlist_name:*}
        map_playlist_name=${channel#*playlist_name: }
        map_playlist_name=${map_playlist_name%, video_codec:*}
        map_video_codec=${channel#*video_codec: }
        map_video_codec=${map_video_codec%, audio_codec:*}
        map_audio_codec=${channel#*audio_codec: }
        map_audio_codec=${map_audio_codec%, video_audio_shift:*}
        map_video_audio_shift=${channel#*video_audio_shift: }
        map_video_audio_shift=${map_video_audio_shift%, quality:*}
        map_quality=${channel#*quality: }
        map_quality=${map_quality%, bitrates:*}
        map_bitrates=${channel#*bitrates: }
        map_bitrates=${map_bitrates%, const:*}
        map_const=${channel#*const: }
        map_const=${map_const%, channel_name:*}
        map_channel_name=${channel#*channel_name: }
        map_channel_name=${map_channel_name%, flv_status:*}
        map_flv_status=${channel#*flv_status: }
        map_flv_status=${map_flv_status%, flv_push_link:*}
        map_flv_push_link=${channel#*flv_push_link: }
        map_flv_push_link=${map_flv_push_link%, flv_pull_link:*}
        map_flv_pull_link=${channel#*flv_pull_link: }

        chnls_pid+=("$map_pid")
        chnls_status+=("$map_status")
        chnls_output_dir_name+=("$map_output_dir_name")
        chnls_playlist_name+=("$map_playlist_name")
        chnls_video_codec+=("$map_video_codec")
        chnls_audio_codec+=("$map_audio_codec")
        chnls_video_audio_shift+=("${map_video_audio_shift:-''}")
        chnls_quality+=("${map_quality:-''}")
        chnls_bitrates+=("${map_bitrates:-''}")
        chnls_const+=("${map_const:-''}")
        chnls_channel_name+=("$map_channel_name")
        chnls_flv_status+=("$map_flv_push_link")
        chnls_flv_push_link+=("${map_flv_push_link:-''}")
        chnls_flv_pull_link+=("${map_flv_pull_link:-''}")
        
    done < <($JQ_FILE -r '.channels | to_entries | map("pid: \(.value.pid), status: \(.value.status), output_dir_name: \(.value.output_dir_name), playlist_name: \(.value.playlist_name), video_codec: \(.value.video_codec), audio_codec: \(.value.audio_codec), video_audio_shift: \(.value.video_audio_shift), quality: \(.value.quality), bitrates: \(.value.bitrates), const: \(.value.const), channel_name: \(.value.channel_name), flv_status: \(.value.flv_status), flv_push_link: \(.value.flv_push_link), flv_pull_link: \(.value.flv_pull_link)") | .[]' "$CHANNELS_FILE")

    [ "$channels_count" == 0 ] && echo -e "$error 没有发现 频道，请检查 !" && exit 1

    return 0
}

ListChannels()
{
    GetChannelsInfo
    chnls_list=""
    for((index = 0; index < "$channels_count"; index++)); do
        chnls_status_index=${chnls_status[index]//\'/}
        chnls_pid_index=${chnls_pid[index]//\'/}
        chnls_output_dir_name_index=${chnls_output_dir_name[index]//\'/}
        chnls_output_dir_root="$LIVE_ROOT/$chnls_output_dir_name_index"
        chnls_video_codec_index=${chnls_video_codec[index]//\'/}
        chnls_audio_codec_index=${chnls_audio_codec[index]//\'/}
        chnls_video_audio_shift_index=${chnls_video_audio_shift[index]//\'/}

        v_or_a=${chnls_video_audio_shift_index%_*}
        if [ "$v_or_a" == "v" ] 
        then
            chnls_video_shift=${chnls_video_audio_shift_index#*_}
            chnls_video_audio_shift_text="画面延迟 $chnls_video_shift 秒"
        elif [ "$v_or_a" == "a" ] 
        then
            chnls_audio_shift=${chnls_video_audio_shift_index#*_}
            chnls_video_audio_shift_text="声音延迟 $chnls_audio_shift 秒"
        else
            chnls_video_audio_shift_text="不设置"
        fi

        chnls_quality_index=${chnls_quality[index]//\'/}
        chnls_playlist_name_index=${chnls_playlist_name[index]//\'/}
        chnls_const_index=${chnls_const[index]//\'/}
        if [ "$chnls_const_index" == "no" ] 
        then
            chnls_const_index_text=" 固定频率:否"
        else
            chnls_const_index_text=" 固定频率:是"
        fi
        chnls_bitrates_index=${chnls_bitrates[index]//\'/}
        #if [ -z "$chnls_bitrates_index" ] 
        #then
        #    if [ -z "$d_bitrates" ] 
        #    then
        #        d_bitrates="900-1280x720"
        #    fi
        #    $JQ_FILE '(.channels[]|select(.pid=='"$chnls_pid_index"')|.bitrates)='"$d_bitrates"'' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        #    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        #    chnls_bitrates_index=$d_bitrates
        #fi
        chnls_quality_text=""
        chnls_bitrates_text=""
        chnls_playlist_file_text=""

        if [ -n "$chnls_bitrates_index" ] 
        then
            while IFS= read -r chnls_br
            do
                if [[ "$chnls_br" == *"-"* ]]
                then
                    chnls_br_a=$(echo "$chnls_br" | cut -d- -f1)
                    chnls_br_b=" 分辨率: "$(echo "$chnls_br" | cut -d- -f2)
                    chnls_quality_text="${chnls_quality_text}[ -maxrate ${chnls_br_a}k -bufsize ${chnls_br_a}k${chnls_br_b} ] "
                    chnls_bitrates_text="${chnls_bitrates_text}[ 比特率 ${chnls_br_a}k${chnls_br_b}${chnls_const_index_text} ] "
                    chnls_playlist_file_text="$chnls_playlist_file_text$green$chnls_output_dir_root/${chnls_playlist_name_index}_$chnls_br_a.m3u8$plain "
                else
                    chnls_quality_text="${chnls_quality_text}[ -maxrate ${chnls_br}k -bufsize ${chnls_br}k ] "
                    chnls_bitrates_text="${chnls_bitrates_text}[ 比特率 ${chnls_br}k${chnls_const_index_text} ] "
                    chnls_playlist_file_text="$chnls_playlist_file_text$green$chnls_output_dir_root/${chnls_playlist_name_index}_$chnls_br.m3u8$plain "
                fi
            done <<< ${chnls_bitrates_index//,/$'\n'}
        else
            chnls_playlist_file_text="$chnls_playlist_file_text$green$chnls_output_dir_root/${chnls_playlist_name_index}.m3u8$plain "
        fi
        
        chnls_channel_name_index=${chnls_channel_name[index]//\'/}
        chnls_flv_status_index=${chnls_flv_status[index]//\'/}
        chnls_flv_push_link_index=${chnls_flv_push_link[index]//\'/}
        chnls_flv_pull_link_index=${chnls_flv_pull_link[index]//\'/}

        if [ -z "${kind:-}" ] 
        then
            if [ "$chnls_status_index" == "on" ]
            then
                if kill -0 "$chnls_pid_index" 2> /dev/null 
                then
                    working=0
                    while IFS= read -r ffmpeg_pid 
                    do
                        if [ -z "$ffmpeg_pid" ] 
                        then
                            working=1
                        else
                            while IFS= read -r real_ffmpeg_pid 
                            do
                                if [ -z "$real_ffmpeg_pid" ] 
                                then
                                    if kill -0 "$ffmpeg_pid" 2> /dev/null 
                                    then
                                        working=1
                                    fi
                                else
                                    if kill -0 "$real_ffmpeg_pid" 2> /dev/null 
                                    then
                                        working=1
                                    fi
                                fi
                            done <<< $(pgrep -P "$ffmpeg_pid")
                        fi
                    done <<< $(pgrep -P "$chnls_pid_index")

                    if [ "$working" == 1 ] 
                    then
                        chnls_status_text=$green"开启"$plain
                    else
                        chnls_status_text=$red"关闭"$plain
                        $JQ_FILE '(.channels[]|select(.pid=='"$chnls_pid_index"')|.status)="off"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
                        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
                        chnl_pid=$chnls_pid_index
                        StopChannel
                    fi
                else
                    chnls_status_text=$red"关闭"$plain
                    $JQ_FILE '(.channels[]|select(.pid=='"$chnls_pid_index"')|.status)="off"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
                    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
                    chnl_pid=$chnls_pid_index
                    StopChannel
                fi
            else
                chnls_status_text=$red"关闭"$plain
            fi
        fi

        if [ -n "$chnls_quality_index" ] 
        then
            chnls_video_quality_text="crf值$chnls_quality_index ${chnls_quality_text:-"不设置"}"
        else
            chnls_video_quality_text="比特率值 ${chnls_bitrates_text:-"不设置"}"
        fi

        if [ "$chnls_video_codec_index" == "copy" ] && [ "$chnls_audio_codec_index" == "copy" ]  
        then
            chnls_video_quality_text="原画"
        fi

        if [ -z "${kind:-}" ] 
        then
            chnls_list=$chnls_list"#$((index+1)) 进程ID: $green${chnls_pid_index}$plain 状态: $chnls_status_text 频道名称: $green${chnls_channel_name_index}$plain 编码: $green$chnls_video_codec_index:$chnls_audio_codec_index$plain 延迟: $green$chnls_video_audio_shift_text$plain 视频质量: $green$chnls_video_quality_text$plain m3u8位置: $chnls_playlist_file_text\n\n"
        elif [ "$kind" == "flv" ] 
        then
            if [ "$chnls_flv_status_index" == "on" ] 
            then
                chnls_flv_status_text=$green"开启"$plain
            else
                chnls_flv_status_text=$red"关闭"$plain
            fi
            chnls_list=$chnls_list"#$((index+1)) 进程ID: $green${chnls_pid_index}$plain 状态: $chnls_flv_status_text 频道名称: $green${chnls_channel_name_index}$plain 编码: $green$chnls_video_codec_index:$chnls_audio_codec_index$plain 延迟: $green$chnls_video_audio_shift_text$plain 视频质量: $green$chnls_video_quality_text$plain flv推流地址: $green${chnls_flv_push_link_index:-"无"}$plain flv拉流地址: $green${chnls_flv_pull_link_index:-"无"}$plain\n\n"
        fi
        
    done
    echo && echo -e "=== 频道总数 $green $channels_count $plain"
    echo -e "$chnls_list\n"
}

GetChannelInfo(){
    if [ -z "${d_sync_file:-}" ] 
    then
        GetDefault
    fi
    chnl_info_array=()
    while IFS='' read -r chnl_line
    do
        chnl_info_array+=("$chnl_line");
    done < <($JQ_FILE -r '.channels[] | select(.pid=='"$chnl_pid"') | .[] | @sh' $CHANNELS_FILE)
    chnl_pid=${chnl_info_array[0]//\'/}
    chnl_status=${chnl_info_array[1]//\'/}
    if [ "$chnl_status" == "on" ]
    then
        chnl_status_text=$green"开启"$plain
    else
        chnl_status_text=$red"关闭"$plain
    fi
    chnl_stream_link=${chnl_info_array[2]//\'/}
    chnl_output_dir_name=${chnl_info_array[3]//\'/}
    chnl_output_dir_root="$LIVE_ROOT/$chnl_output_dir_name"
    chnl_playlist_name=${chnl_info_array[4]//\'/}
    chnl_seg_dir_name=${chnl_info_array[5]//\'/}
    chnl_seg_dir_name_text=${chnl_seg_dir_name:-"不使用"}
    chnl_seg_name=${chnl_info_array[6]//\'/}
    chnl_seg_length=${chnl_info_array[7]//\'/}
    chnl_seg_length_text=$chnl_seg_length"s"
    chnl_seg_count=${chnl_info_array[8]//\'/}
    chnl_video_codec=${chnl_info_array[9]//\'/}
    chnl_audio_codec=${chnl_info_array[10]//\'/}
    chnl_video_audio_shift=${chnl_info_array[11]//\'/}

    v_or_a=${chnl_video_audio_shift%_*}
    if [ "$v_or_a" == "v" ] 
    then
        chnl_video_shift=${chnl_video_audio_shift#*_}
        chnl_video_audio_shift_text="画面延迟 $chnl_video_shift 秒"
    elif [ "$v_or_a" == "a" ] 
    then
        chnl_audio_shift=${chnl_video_audio_shift#*_}
        chnl_video_audio_shift_text="声音延迟 $chnl_audio_shift 秒"
    else
        chnl_video_audio_shift_text="不设置"
    fi

    chnl_quality=${chnl_info_array[12]//\'/}
    chnl_const=${chnl_info_array[14]//\'/}
    if [ "$chnl_const" == "no" ]
    then
        chnl_const=""
        chnl_const_text=" 固定频率:否"
    else
        chnl_const="-C"
        chnl_const_text=" 固定频率:是"
    fi
    chnl_bitrates=${chnl_info_array[13]//\'/}
    #if [ -z "$chnl_bitrates" ] 
    #then
    #    if [ -z "$d_bitrates" ] 
    #    then
    #        d_bitrates="900-1280x720"
    #    fi
    #    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.bitrates)='"$d_bitrates"'' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    #    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    #    chnl_bitrates=$d_bitrates
    #fi
    chnl_crf_text=""
    chnl_nocrf_text=""
    chnl_playlist_file_text=""

    if [ -n "$chnl_bitrates" ] 
    then
        while IFS= read -r chnl_br
        do
            if [[ "$chnl_br" == *"-"* ]]
            then
                chnl_br_a=$(echo "$chnl_br" | cut -d- -f1)
                chnl_br_b=" 分辨率: "$(echo "$chnl_br" | cut -d- -f2)
                chnl_crf_text="${chnl_crf_text}[ -maxrate ${chnl_br_a}k -bufsize ${chnl_br_a}k${chnl_br_b} ] "
                chnl_nocrf_text="${chnl_nocrf_text}[ 比特率 ${chnl_br_a}k${chnl_br_b}${chnl_const_text} ] "
                chnl_playlist_file_text="$chnl_playlist_file_text$green$chnl_output_dir_root/${chnl_playlist_name}_$chnl_br_a.m3u8$plain "
            else
                chnl_crf_text="${chnl_crf_text}[ -maxrate ${chnl_br}k -bufsize ${chnl_br}k ] "
                chnl_nocrf_text="${chnl_nocrf_text}[ 比特率 ${chnl_br}k${chnl_const_text} ] "
                chnl_playlist_file_text="$chnl_playlist_file_text$green$chnl_output_dir_root/${chnl_playlist_name}_$chnl_br.m3u8$plain "
            fi
        done <<< ${chnl_bitrates//,/$'\n'}
    else
        chnl_playlist_file_text="$chnl_playlist_file_text$green$chnl_output_dir_root/${chnl_playlist_name}.m3u8$plain "
    fi

    if [ -n "$d_sync_file" ] && [ -n "$d_sync_index" ] && [ -n "$d_sync_pairs" ] && [[ $d_sync_pairs == *"=http"* ]] 
    then
        d_sync_pairs_arr=(${d_sync_pairs//=http/ })
        chnl_playlist_link="http$(echo "${d_sync_pairs_arr[1]}" | cut -d, -f1)/$chnl_output_dir_name/${chnl_playlist_name}_master.m3u8"
        chnl_playlist_link_text="$green$chnl_playlist_link$plain"
    else
        chnl_playlist_link_text="$red请先设置 sync$plain"
    fi

    chnl_encrypt=${chnl_info_array[15]//\'/}
    chnl_key_name=${chnl_info_array[16]//\'/}
    if [ "$chnl_encrypt" == "no" ]
    then
        chnl_encrypt=""
        chnl_encrypt_text=$red"否"$plain
        chnl_key_name_text=$red$chnl_key_name$plain
    else
        chnl_encrypt="-e"
        chnl_encrypt_text=$green"是"$plain
        chnl_key_name_text=$green$chnl_key_name$plain
    fi
    chnl_input_flags=${chnl_info_array[17]}
    chnl_input_flags_text=${chnl_input_flags//\'/}
    chnl_output_flags=${chnl_info_array[18]}
    chnl_output_flags_text=${chnl_output_flags//\'/}
    chnl_channel_name=${chnl_info_array[19]//\'/}
    chnl_flv_status=${chnl_info_array[20]//\'/}
    if [ "$chnl_flv_status" == "on" ]
    then
        chnl_flv_status_text=$green"开启"$plain
    else
        chnl_flv_status_text=$red"关闭"$plain
    fi

    chnl_flv_push_link=${chnl_info_array[21]//\'/}
    chnl_flv_pull_link=${chnl_info_array[22]//\'/}

    if [ -n "$chnl_quality" ] 
    then
        chnl_video_quality_text="crf值$chnl_quality ${chnl_crf_text:-"不设置"}"
    else
        chnl_video_quality_text="比特率值 ${chnl_nocrf_text:-"不设置"}"
    fi

    if [ "$chnl_video_codec" == "copy" ] && [ "$chnl_audio_codec" == "copy" ]  
    then
        chnl_video_quality_text="原画"
        chnl_playlist_link=${chnl_playlist_link:-""}
        chnl_playlist_link=${chnl_playlist_link//_master.m3u8/.m3u8}
        chnl_playlist_link_text=${chnl_playlist_link_text//_master.m3u8/.m3u8}
    elif [ -z "$chnl_bitrates" ] 
    then
        chnl_playlist_link=${chnl_playlist_link:-""}
        chnl_playlist_link=${chnl_playlist_link//_master.m3u8/.m3u8}
        chnl_playlist_link_text=${chnl_playlist_link_text//_master.m3u8/.m3u8}
    fi
}

ViewChannelInfo()
{
    echo "===================================================" && echo
    echo -e " 频道 [$chnl_channel_name] 的配置信息：" && echo
    echo -e " 进程ID\t    : $green$chnl_pid$plain"

    if [ -z "${kind:-}" ] 
    then
        echo -e " 状态\t    : $chnl_status_text"
        echo -e " m3u8名称   : $green$chnl_playlist_name$plain"
        echo -e " m3u8位置   : $chnl_playlist_file_text"
        echo -e " m3u8链接   : $chnl_playlist_link_text"
        echo -e " 段子目录   : $green$chnl_seg_dir_name_text$plain"
        echo -e " 段名称\t    : $green$chnl_seg_name$plain"
        echo -e " 段时长\t    : $green$chnl_seg_length_text$plain"
        echo -e " m3u8包含段数目 : $green$chnl_seg_count$plain"
        echo -e " 加密\t    : $chnl_encrypt_text"
        if [ -n "$chnl_encrypt" ] 
        then
            echo -e " key名称    : $chnl_key_name_text"
        fi
    elif [ "$kind" == "flv" ] 
    then
        echo -e " 状态\t    : $chnl_flv_status_text"
        echo -e " 推流地址   : $green$chnl_flv_push_link$plain"
        echo -e " 拉流地址   : $green$chnl_flv_pull_link$plain"
    fi
    
    echo -e " 视频源\t    : $green$chnl_stream_link$plain"
    #echo -e " 目录\t    : $green$chnl_output_dir_root$plain"
    echo -e " 视频编码   : $green$chnl_video_codec$plain"
    echo -e " 音频编码   : $green$chnl_audio_codec$plain"
    echo -e " 视频质量   : $green$chnl_video_quality_text$plain"
    echo -e " 延迟\t    : $green$chnl_video_audio_shift_text$plain"

    echo -e " input flags    : $green${chnl_input_flags_text:-"不设置"}$plain"
    echo -e " output flags   : $green${chnl_output_flags_text:-"不设置"}$plain"
    echo
}

InputChannelsPids()
{
    echo -e "请输入频道的进程ID "
    echo -e "$tip 多个进程ID用空格分隔 "
    while read -p "(默认: 取消):" chnls_pids
    do
        error=0
        IFS=" " read -ra chnls_pids_arr <<< "$chnls_pids"
        [ -z "$chnls_pids" ] && echo "已取消..." && exit 1
        for chnl_pid in "${chnls_pids_arr[@]}"
        do
            case "$chnl_pid" in
                *[!0-9]*)
                    error=1
                ;;
                *)
                    if [ -z "$($JQ_FILE '.channels[] | select(.pid=='"$chnl_pid"')' $CHANNELS_FILE)" ]
                    then
                        error=2
                    fi
                ;;
            esac
        done

        case $error in
            1) echo -e "$error 请输入正确的数字！"
            ;;
            2) echo -e "$error 请输入正确的进程ID！"
            ;;
            *) break;
            ;;
        esac
    done
}

ViewChannelMenu(){
    ListChannels
    InputChannelsPids
    for chnl_pid in "${chnls_pids_arr[@]}"
    do
        GetChannelInfo
        ViewChannelInfo
    done
}

SetStreamLink()
{
    echo && echo "请输入直播源( mpegts / hls / flv ...)"
    echo -e "$tip hls 链接需包含 .m3u8 标识" && echo
    read -p "(默认: 取消):" stream_link
    [ -z "$stream_link" ] && echo "已取消..." && exit 1
    echo && echo -e "	直播源: $green $stream_link $plain" && echo
}

SetOutputDirName()
{
    echo "请输入频道输出目录名称"
    echo -e "$tip 是名称不是路径" && echo
    while read -p "(默认: 随机名称):" output_dir_name
    do
        if [ -z "$output_dir_name" ] 
        then
            while :;do
                output_dir_name=$(RandOutputDirName)
                if [ -z "$($JQ_FILE '.channels[] | select(.output_dir_name=="'"$output_dir_name"'")' $CHANNELS_FILE)" ] 
                then
                    break 2
                fi
            done
        elif [ -z "$($JQ_FILE '.channels[] | select(.output_dir_name=="'"$output_dir_name"'")' $CHANNELS_FILE)" ]  
        then
            break
        else
            echo && echo -e "$error 目录已存在！" && echo
        fi
    done
    echo && echo -e "	目录名称: $green $output_dir_name $plain" && echo
}

SetPlaylistName()
{
    echo "请输入m3u8名称(前缀)"
    read -p "(默认: 随机名称):" playlist_name
    playlist_name=${playlist_name:-$(RandPlaylistName)}
    echo && echo -e "	m3u8名称: $green $playlist_name $plain" && echo
}

SetSegDirName()
{
    echo "请输入段所在子目录名称"
    read -p "(默认: $d_seg_dir_name_text):" seg_dir_name
    seg_dir_name=${seg_dir_name:-$d_seg_dir_name}
    seg_dir_name_text=${seg_dir_name:-"不使用"}
    echo && echo -e "	段子目录名: $green $seg_dir_name_text $plain" && echo
}

SetSegName()
{
    echo "请输入段名称"
    read -p "(默认: 跟m3u8名称相同):" seg_name
    if [ -z "${playlist_name:-}" ] 
    then
        playlist_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').playlist_name' "$CHANNELS_FILE")
    fi
    seg_name=${seg_name:-$playlist_name}
    echo && echo -e "	段名称: $green $seg_name $plain" && echo 
}

SetSegLength()
{
    echo -e "请输入段的时长(单位：s)"
    while read -p "(默认: $d_seg_length):" seg_length
    do
        case "$seg_length" in
            "")
                seg_length=$d_seg_length
                break
            ;;
            *[!0-9]*)
                echo -e "$error 请输入正确的数字(大于0) "
            ;;
            *)
                if [ "$seg_length" -ge 1 ]; then
                    break
                else
                    echo -e "$error 请输入正确的数字(大于0)"
                fi
            ;;
        esac
    done
    echo && echo -e "	段时长: $green ${seg_length}s $plain" && echo
}

SetSegCount()
{
    echo "请输入m3u8文件包含的段数目，ffmpeg分割的数目是其2倍"
    echo -e "$tip 如果填0就是无限"
    while read -p "(默认: $d_seg_count):" seg_count
    do
        case "$seg_count" in
            "")
                seg_count=$d_seg_count
                break
            ;;
            *[!0-9]*)
                echo -e "$error 请输入正确的数字(大于等于0) "
            ;;
            *)
                if [ "$seg_count" -ge 0 ]; then
                    break
                else
                    echo -e "$error 请输入正确的数字(大于等于0)"
                fi
            ;;
        esac
    done
    echo && echo -e "	段数目: $green $seg_count $plain" && echo
}

SetVideoCodec()
{
    echo "请输入视频编码(不需要转码时输入 copy)"
    read -p "(默认: $d_video_codec):" video_codec
    video_codec=${video_codec:-$d_video_codec}
    echo && echo -e "	视频编码: $green $video_codec $plain" && echo
}

SetAudioCodec()
{
    echo "请输入音频编码(不需要转码时输入 copy)"
    read -p "(默认: $d_audio_codec):" audio_codec
    audio_codec=${audio_codec:-$d_audio_codec}
    echo && echo -e "	音频编码: $green $audio_codec $plain" && echo
}

SetQuality()
{
    echo -e "请输入输出视频质量"
    echo -e "$tip 改变CRF，数字越大越视频质量越差，如果设置CRF则无法用比特率控制视频质量"
    while read -p "(默认: $d_quality_text):" quality
    do
        case "$quality" in
            "")
                quality=$d_quality
                break
            ;;
            *[!0-9]*)
                echo -e "$error 请输入正确的数字(大于0,小于等于63)或直接回车 "
            ;;
            *)
                if [ "$quality" -gt 0 ] && [ "$quality" -lt 63 ]
                then
                    break
                else
                    echo -e "$error 请输入正确的数字(大于0,小于等于63)或直接回车 "
                fi
            ;;
        esac
    done
    echo && echo -e "	crf视频质量: $green ${quality:-"不设置"} $plain" && echo
}

SetBitrates()
{
    if [ -z "$d_bitrates" ] 
    then
        d_bitrates_text="不设置"
    else
        d_bitrates_text=${d_bitrates}
    fi

    echo "请输入比特率, 可以输入 omit 省略此选项(ffmpeg自行判断输出比特率)"

    if [ -z "$quality" ] 
    then
        echo -e "$tip 用于指定输出视频比特率"
    else
        echo -e "$tip 用于 -maxrate 和 -bufsize"
    fi
    
    if [ -z "${kind:-}" ] 
    then
        echo -e "$tip 多个比特率用逗号分隔(生成自适应码流)
    同时可以指定输出的分辨率(比如：600-600x400,900-1280x720)"
    fi
    read -p "(默认: $d_bitrates_text):" bitrates
    bitrates=${bitrates:-$d_bitrates}
    if [ "$bitrates" == "omit" ] 
    then
        bitrates=""
    fi
    echo && echo -e "	比特率: $green ${bitrates:-"不设置"} $plain" && echo
}

SetConst()
{
    echo "是否使用固定码率[y/N]"
    read -p "(默认: $d_const_yn):" const_yn
    const_yn=${const_yn:-$d_const_yn}
    if [[ "$const_yn" == [Yy] ]]
    then
        const="-C"
        const_yn="yes"
        const_text="是"
    else
        const=""
        const_yn="no"
        const_text="否"
    fi
    echo && echo -e "	固定码率: $green $const_text $plain" && echo 
}

SetEncrypt()
{
    echo "是否加密段[y/N]"
    read -p "(默认: $d_encrypt_yn):" encrypt_yn
    encrypt_yn=${encrypt_yn:-$d_encrypt_yn}
    if [[ "$encrypt_yn" == [Yy] ]]
    then
        encrypt="-e"
        encrypt_yn="yes"
        encrypt_text="是"
    else
        encrypt=""
        encrypt_yn="no"
        encrypt_text="否"
    fi
    echo && echo -e "	加密段: $green $encrypt_text $plain" && echo 
}

SetKeyName()
{
    echo "请输入key名称"
    read -p "(默认: 跟m3u8名称相同):" key_name
    if [ -z "${playlist_name:-}" ] 
    then
        playlist_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').playlist_name' "$CHANNELS_FILE")
    fi
    key_name=${key_name:-$playlist_name}
    echo && echo -e "	key名称: $green $key_name $plain" && echo 
}

SetInputFlags()
{
    if [[ ${stream_link:-} == *".m3u8"* ]] 
    then
        d_input_flags=${d_input_flags//-reconnect_at_eof 1/}
    elif [ "${stream_link:0:4}" == "rtmp" ] 
    then
        d_input_flags=${d_input_flags//-timeout 2000000000/}
        d_input_flags=${d_input_flags//-reconnect 1/}
        d_input_flags=${d_input_flags//-reconnect_at_eof 1/}
        d_input_flags=${d_input_flags//-reconnect_streamed 1/}
        d_input_flags=${d_input_flags//-reconnect_delay_max 2000/}
    fi
    echo "请输入input flags"
    read -p "(默认: $d_input_flags):" input_flags
    input_flags=${input_flags:-$d_input_flags}
    echo && echo -e "	input flags: $green $input_flags $plain" && echo 
}

SetOutputFlags()
{
    if [ -z "$d_output_flags" ] 
    then
        d_output_flags_text="不设置"
        echo "请输入output flags";
    else
        d_output_flags_text=${d_output_flags}
        echo "请输入output flags, 可以输入 copy 省略此选项(不需要转码时)"
    fi
    read -p "(默认: $d_output_flags_text):" output_flags
    output_flags=${output_flags:-$d_output_flags}
    if [ "$output_flags" == "copy" ] 
    then
        output_flags=""
        video_codec="copy"
        audio_codec="copy"
        quality=""
        bitrates=""
        const=""
        const_yn="no"
        const_text="否"
    fi
    echo && echo -e "	output flags: $green ${output_flags:-"不设置"} $plain" && echo 
}

SetVideoAudioShift()
{
    echo && echo -e "画面或声音延迟？
    ${green}1.$plain 设置 画面延迟
    ${green}2.$plain 设置 声音延迟
    ${green}3.$plain 不设置
    " && echo
    while read -p "(默认: $d_video_audio_shift_text):" video_audio_shift_num
    do
        case $video_audio_shift_num in
            "") 
                if [ -n "${d_video_shift:-}" ] 
                then
                    video_shift=$d_video_shift
                elif [ -n "${d_audio_shift:-}" ] 
                then
                    audio_shift=$d_audio_shift
                fi

                video_audio_shift=""
                video_audio_shift_text=$d_video_audio_shift_text
                break
            ;;
            1) 
                echo && echo "请输入延迟时间（比如 0.5）"
                read -p "(默认: 返回上级选项): " video_shift
                if [ -n "$video_shift" ] 
                then
                    video_audio_shift="v_$video_shift"
                    video_audio_shift_text="画面延迟 $video_shift 秒"
                    break
                else
                    echo
                fi
            ;;
            2) 
                echo && echo "请输入延迟时间（比如 0.5）"
                read -p "(默认: 返回上级选项): " audio_shift
                if [ -n "$audio_shift" ] 
                then
                    video_audio_shift="a_$audio_shift"
                    video_audio_shift_text="声音延迟 $audio_shift 秒"
                    break
                else
                    echo
                fi
            ;;
            3) 
                video_audio_shift_text="不设置"
                break
            ;;
            *) echo && echo -e "$error 请输入正确序号(1、2、3)或直接回车 " && echo
            ;;
        esac
    done

    echo && echo -e "	延迟: $green $video_audio_shift_text $plain" && echo 
}

SetChannelName()
{
    echo "请输入频道名称(可以是中文)"
    read -p "(默认: 跟m3u8名称相同):" channel_name
    if [ -z "${playlist_name:-}" ] 
    then
        playlist_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').playlist_name' "$CHANNELS_FILE")
    fi
    channel_name=${channel_name:-$playlist_name}
    echo && echo -e "	频道名称: $green $channel_name $plain" && echo
}

SetFlvPush()
{
    echo && echo "请输入推流地址(比如 rtmp://127.0.0.1/live/xxx )" && echo
    while read -p "(默认: 取消):" flv_push_link
    do
        [ -z "$flv_push_link" ] && echo "已取消..." && exit 1
        if [ -z "$($JQ_FILE '.channels[] | select(.flv_push_link=="'"$flv_push_link"'")' $CHANNELS_FILE)" ]
        then
            break
        else
            echo -e "$error 推流地址已存在！请重新输入" && echo
        fi
    done
    echo && echo -e "	推流地址: $green $flv_push_link $plain" && echo
}

SetFlvPull()
{
    echo && echo "请输入拉流(播放)地址"
    echo -e "$tip 监控会验证此链接来确定是否重启频道，如果不确定可以先留空" && echo
    read -p "(默认: 不设置):" flv_pull_link
    echo && echo -e "	拉流地址: $green ${flv_pull_link:-"不设置"} $plain" && echo
}

FlvStreamCreatorWithShift()
{
    trap '' HUP INT QUIT TERM
    trap 'MonitorError $LINENO' ERR
    pid="$BASHPID"
    case $from in
        "AddChannel") 
            $JQ_FILE '.channels += [
                {
                    "pid":'"$pid"',
                    "status":"off",
                    "stream_link":"'"$stream_link"'",
                    "output_dir_name":"'"$output_dir_name"'",
                    "playlist_name":"'"$playlist_name"'",
                    "seg_dir_name":"'"$SEGMENT_DIRECTORY"'",
                    "seg_name":"'"$seg_name"'",
                    "seg_length":'"$seg_length"',
                    "seg_count":'"$seg_count"',
                    "video_codec":"'"$VIDEO_CODEC"'",
                    "audio_codec":"'"$AUDIO_CODEC"'",
                    "video_audio_shift":"'"$video_audio_shift"'",
                    "quality":"'"$quality"'",
                    "bitrates":"'"$bitrates"'",
                    "const":"'"$const_yn"'",
                    "encrypt":"'"$encrypt_yn"'",
                    "key_name":"'"$key_name"'",
                    "input_flags":"'"$FFMPEG_INPUT_FLAGS"'",
                    "output_flags":"'"$FFMPEG_FLAGS"'",
                    "channel_name":"'"$channel_name"'",
                    "flv_status":"on",
                    "flv_push_link":"'"$flv_push_link"'",
                    "flv_pull_link":"'"$flv_pull_link"'"
                }
            ]' "$CHANNELS_FILE" > "${CHANNELS_TMP}_flv_shift"
            mv "${CHANNELS_TMP}_flv_shift" "$CHANNELS_FILE"
            action="add"
            SyncFile

            if [ -n "$bitrates" ] 
            then
                bitrates=${bitrates%%,*}
                bitrates=${bitrates%%-*}
                bitrates_command="-b:v ${bitrates}k"
            else
                bitrates_command=""
            fi

            if [ -n "${video_shift:-}" ] 
            then
                map_command="-itsoffset $video_shift -i $stream_link -map 0:v -map 1:a"
            elif [ -n "${audio_shift:-}" ] 
            then
                map_command="-itsoffset $audio_shift -i $stream_link -map 0:a -map 1:v"
            else
                map_command=""
            fi

            $FFMPEG $FFMPEG_INPUT_FLAGS -i "$stream_link" $map_command \
            -y -vcodec "$video_codec" -acodec "$audio_codec" $bitrates_command \
            $FFMPEG_FLAGS -f flv "$flv_push_link" || true

            $JQ_FILE '(.channels[]|select(.pid=='"$pid"')|.flv_status)="off"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_flv_shift"
            mv "${CHANNELS_TMP}_flv_shift" "$CHANNELS_FILE"

            date_now=$(date -d now "+%m-%d %H:%M:%S")
            printf '%s\n' "$date_now $channel_name flv 关闭" >> "$MONITOR_LOG"
            chnl_pid=$pid
            action="stop"
            SyncFile
            kill -9 "$chnl_pid"
        ;;
        "StartChannel") 
            new_pid=$pid
            $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.pid)='"$new_pid"'|(.channels[]|select(.pid=='"$new_pid"')|.flv_status)="on"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_flv_shift"
            mv "${CHANNELS_TMP}_flv_shift" "$CHANNELS_FILE"
            action=${action:-"start"}
            SyncFile

            if [ -n "$chnl_bitrates" ] 
            then
                bitrates=${chnl_bitrates%%,*}
                bitrates=${chnl_bitrates%%-*}
                bitrates_command="-b:v ${chnl_bitrates}k"
            else
                bitrates_command=""
            fi

            if [ -n "${chnl_video_shift:-}" ] 
            then
                map_command="-itsoffset $chnl_video_shift -i $chnl_stream_link -map 0:v -map 1:a"
            elif [ -n "${chnl_audio_shift:-}" ] 
            then
                map_command="-itsoffset $chnl_audio_shift -i $chnl_stream_link -map 0:a -map 1:v"
            else
                map_command=""
            fi

            $FFMPEG $FFMPEG_INPUT_FLAGS -i "$chnl_stream_link" $map_command \
            -y -vcodec "$chnl_video_codec" -acodec "$chnl_audio_codec" $bitrates_command \
            $FFMPEG_FLAGS -f flv "$chnl_flv_push_link" || true

            $JQ_FILE '(.channels[]|select(.pid=='"$new_pid"')|.flv_status)="off"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_flv_shift"
            mv "${CHANNELS_TMP}_flv_shift" "$CHANNELS_FILE"

            date_now=$(date -d now "+%m-%d %H:%M:%S")
            printf '%s\n' "$date_now $chnl_channel_name flv 关闭" >> "$MONITOR_LOG"
            chnl_pid=$new_pid
            action="stop"
            SyncFile
            kill -9 "$chnl_pid"
        ;;
        "command") 
            $JQ_FILE '.channels += [
                {
                    "pid":'"$pid"',
                    "status":"off",
                    "stream_link":"'"$stream_link"'",
                    "output_dir_name":"'"$output_dir_name"'",
                    "playlist_name":"'"$playlist_name"'",
                    "seg_dir_name":"'"$SEGMENT_DIRECTORY"'",
                    "seg_name":"'"$seg_name"'",
                    "seg_length":'"$seg_length"',
                    "seg_count":'"$seg_count"',
                    "video_codec":"'"$VIDEO_CODEC"'",
                    "audio_codec":"'"$AUDIO_CODEC"'",
                    "video_audio_shift":"'"$video_audio_shift"'",
                    "quality":"'"$quality"'",
                    "bitrates":"'"$bitrates"'",
                    "const":"'"$const_yn"'",
                    "encrypt":"'"$encrypt_yn"'",
                    "key_name":"'"$key_name"'",
                    "input_flags":"'"$FFMPEG_INPUT_FLAGS"'",
                    "output_flags":"'"$FFMPEG_FLAGS"'",
                    "channel_name":"'"$channel_name"'",
                    "flv_status":"on",
                    "flv_push_link":"'"$flv_push_link"'",
                    "flv_pull_link":"'"$flv_pull_link"'"
                }
            ]' "$CHANNELS_FILE" > "${CHANNELS_TMP}_flv_shift"
            mv "${CHANNELS_TMP}_flv_shift" "$CHANNELS_FILE"
            action="add"
            SyncFile

            if [ -n "${bitrates:-}" ] 
            then
                bitrates=${bitrates%%,*}
                bitrates=${bitrates%%-*}
                bitrates_command="-b:v ${bitrates}k"
            else
                bitrates_command=""
            fi

            if [ -n "${video_shift:-}" ] 
            then
                map_command="-itsoffset $video_shift -i $stream_link -map 0:v -map 1:a"
            elif [ -n "${audio_shift:-}" ] 
            then
                map_command="-itsoffset $audio_shift -i $stream_link -map 0:a -map 1:v"
            else
                map_command=""
            fi

            $FFMPEG $FFMPEG_INPUT_FLAGS -i "$stream_link" $map_command -y \
            -vcodec "$video_codec" -acodec "$audio_codec" $bitrates_command \
            $FFMPEG_FLAGS -f flv "$flv_push_link" || true

            $JQ_FILE '(.channels[]|select(.pid=='"$pid"')|.flv_status)="off"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_flv_shift"
            mv "${CHANNELS_TMP}_flv_shift" "$CHANNELS_FILE"

            date_now=$(date -d now "+%m-%d %H:%M:%S")
            printf '%s\n' "$date_now $channel_name flv 关闭" >> "$MONITOR_LOG"
            chnl_pid=$pid
            action="stop"
            SyncFile
            kill -9 "$chnl_pid"
        ;;
    esac
}

HlsStreamCreatorWithShift()
{
    trap '' HUP INT QUIT TERM
    trap 'MonitorError $LINENO' ERR
    pid="$BASHPID"
    case $from in
        "AddChannel") 
            mkdir -p "$output_dir_root"
            $JQ_FILE '.channels += [
                {
                    "pid":'"$pid"',
                    "status":"on",
                    "stream_link":"'"$stream_link"'",
                    "output_dir_name":"'"$output_dir_name"'",
                    "playlist_name":"'"$playlist_name"'",
                    "seg_dir_name":"'"$SEGMENT_DIRECTORY"'",
                    "seg_name":"'"$seg_name"'",
                    "seg_length":'"$seg_length"',
                    "seg_count":'"$seg_count"',
                    "video_codec":"'"$VIDEO_CODEC"'",
                    "audio_codec":"'"$AUDIO_CODEC"'",
                    "video_audio_shift":"'"$video_audio_shift"'",
                    "quality":"'"$quality"'",
                    "bitrates":"'"$bitrates"'",
                    "const":"'"$const_yn"'",
                    "encrypt":"'"$encrypt_yn"'",
                    "key_name":"'"$key_name"'",
                    "input_flags":"'"$FFMPEG_INPUT_FLAGS"'",
                    "output_flags":"'"$FFMPEG_FLAGS"'",
                    "channel_name":"'"$channel_name"'",
                    "flv_status":"off",
                    "flv_push_link":"",
                    "flv_pull_link":""
                }
            ]' "$CHANNELS_FILE" > "${CHANNELS_TMP}_shift"
            mv "${CHANNELS_TMP}_shift" "$CHANNELS_FILE"
            action="add"
            SyncFile

            if [ -n "$bitrates" ] 
            then
                output_name="${playlist_name}_${bitrates}_%05d.ts"
            else
                output_name="${playlist_name}_%05d.ts"
            fi

            if [ -n "${video_shift:-}" ] 
            then
                map_command="-itsoffset $video_shift -i $stream_link -map 0:v -map 1:a"
            elif [ -n "${audio_shift:-}" ] 
            then
                map_command="-itsoffset $audio_shift -i $stream_link -map 0:a -map 1:v"
            else
                map_command=""
            fi

            $FFMPEG $FFMPEG_INPUT_FLAGS -i "$stream_link" $map_command -y \
            -vcodec "$video_codec" -acodec "$audio_codec" \
            -threads 0 -flags -global_header -f segment -segment_list "$output_dir_root/$playlist_name.m3u8" \
            -segment_time "$seg_length" -segment_format mpeg_ts -segment_list_flags +live \
            -segment_list_size "$seg_count" -segment_wrap $((seg_count * 2)) $FFMPEG_FLAGS "$output_dir_root/$output_name" || true

            $JQ_FILE '(.channels[]|select(.pid=='"$pid"')|.status)="off"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_shift"
            mv "${CHANNELS_TMP}_shift" "$CHANNELS_FILE"
            rm -rf "$LIVE_ROOT/${output_dir_name:-'notfound'}"

            date_now=$(date -d now "+%m-%d %H:%M:%S")
            printf '%s\n' "$date_now $channel_name HLS 关闭" >> "$MONITOR_LOG"
            chnl_pid=$pid
            action="stop"
            SyncFile
            kill -9 "$pid"
        ;;
        "StartChannel") 
            mkdir -p "$chnl_output_dir_root"
            new_pid=$pid
            $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.pid)='"$new_pid"'|(.channels[]|select(.pid=='"$new_pid"')|.status)="on"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_shift"
            mv "${CHANNELS_TMP}_shift" "$CHANNELS_FILE"
            action=${action:-"start"}
            SyncFile

            if [ -n "$chnl_bitrates" ] 
            then
                output_name="${chnl_playlist_name}_${chnl_bitrates}_%05d.ts"
            else
                output_name="${chnl_playlist_name}_%05d.ts"
            fi

            if [ -n "${chnl_video_shift:-}" ] 
            then
                map_command="-itsoffset $chnl_video_shift -i $chnl_stream_link -map 0:v -map 1:a"
            elif [ -n "${chnl_audio_shift:-}" ] 
            then
                map_command="-itsoffset $chnl_audio_shift -i $chnl_stream_link -map 0:a -map 1:v"
            else
                map_command=""
            fi

            $FFMPEG $FFMPEG_INPUT_FLAGS -i "$chnl_stream_link" $map_command -y \
            -vcodec "$chnl_video_codec" -acodec "$chnl_audio_codec" \
            -threads 0 -flags -global_header -f segment -segment_list "$chnl_output_dir_root/$chnl_playlist_name.m3u8" \
            -segment_time "$chnl_seg_length" -segment_format mpeg_ts -segment_list_flags +live \
            -segment_list_size "$chnl_seg_count" -segment_wrap $((chnl_seg_count * 2)) $FFMPEG_FLAGS "$chnl_output_dir_root/$output_name" || true

            $JQ_FILE '(.channels[]|select(.pid=='"$new_pid"')|.status)="off"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_shift"
            mv "${CHANNELS_TMP}_shift" "$CHANNELS_FILE"
            rm -rf "$LIVE_ROOT/${chnl_output_dir_name:-'notfound'}"

            date_now=$(date -d now "+%m-%d %H:%M:%S")
            printf '%s\n' "$date_now $chnl_channel_name HLS 关闭" >> "$MONITOR_LOG"
            chnl_pid=$new_pid
            action="stop"
            SyncFile
            kill -9 "$new_pid"
        ;;
        "command") 
            mkdir -p "$output_dir_root"
            $JQ_FILE '.channels += [
                {
                    "pid":'"$pid"',
                    "status":"on",
                    "stream_link":"'"$stream_link"'",
                    "output_dir_name":"'"$output_dir_name"'",
                    "playlist_name":"'"$playlist_name"'",
                    "seg_dir_name":"'"$SEGMENT_DIRECTORY"'",
                    "seg_name":"'"$seg_name"'",
                    "seg_length":'"$seg_length"',
                    "seg_count":'"$seg_count"',
                    "video_codec":"'"$VIDEO_CODEC"'",
                    "audio_codec":"'"$AUDIO_CODEC"'",
                    "video_audio_shift":"'"$video_audio_shift"'",
                    "quality":"'"$quality"'",
                    "bitrates":"'"$bitrates"'",
                    "const":"'"$const_yn"'",
                    "encrypt":"'"$encrypt_yn"'",
                    "key_name":"'"$key_name"'",
                    "input_flags":"'"$FFMPEG_INPUT_FLAGS"'",
                    "output_flags":"'"$FFMPEG_FLAGS"'",
                    "channel_name":"'"$channel_name"'",
                    "flv_status":"off",
                    "flv_push_link":"",
                    "flv_pull_link":""
                }
            ]' "$CHANNELS_FILE" > "${CHANNELS_TMP}_shift"
            mv "${CHANNELS_TMP}_shift" "$CHANNELS_FILE"
            action="add"
            SyncFile

            if [ -n "${bitrates:-}" ] 
            then
                output_name="${playlist_name}_${bitrates}_%05d.ts"
            else
                output_name="${playlist_name}_%05d.ts"
            fi
            
            if [ -n "${video_shift:-}" ] 
            then
                map_command="-itsoffset $video_shift -i $stream_link -map 0:v -map 1:a"
            elif [ -n "${audio_shift:-}" ] 
            then
                map_command="-itsoffset $audio_shift -i $stream_link -map 0:a -map 1:v"
            else
                map_command=""
            fi

            $FFMPEG $FFMPEG_INPUT_FLAGS -i "$stream_link" $map_command -y \
            -vcodec "$video_codec" -acodec "$audio_codec" \
            -threads 0 -flags -global_header -f segment -segment_list "$output_dir_root/$playlist_name.m3u8" \
            -segment_time "$seg_length" -segment_format mpeg_ts -segment_list_flags +live \
            -segment_list_size "$seg_count" -segment_wrap $((seg_count * 2)) $FFMPEG_FLAGS "$output_dir_root/$output_name" || true

            $JQ_FILE '(.channels[]|select(.pid=='"$pid"')|.status)="off"' "$CHANNELS_FILE" > "${CHANNELS_TMP}_shift"
            mv "${CHANNELS_TMP}_shift" "$CHANNELS_FILE"
            rm -rf "$LIVE_ROOT/${output_dir_name:-'notfound'}"

            date_now=$(date -d now "+%m-%d %H:%M:%S")
            printf '%s\n' "$date_now $channel_name HLS 关闭" >> "$MONITOR_LOG"
            chnl_pid=$pid
            action="stop"
            SyncFile
            kill -9 "$pid"
        ;;
    esac
}

AddChannel()
{
    [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
    GetDefault
    SetStreamLink
    SetVideoCodec
    SetAudioCodec
    SetVideoAudioShift

    quality_command=""
    bitrates_command=""
    if [ "$video_codec" == "copy" ] && [ "$audio_codec" == "copy" ]
    then
        quality=""
        bitrates=""
        master=0
        const=""
        const_yn="no"
        const_text="否"
    else
        SetQuality
        if [ -n "$quality" ] 
        then
            quality_command="-q $quality"
        fi
        SetBitrates
        if [ -n "$bitrates" ] 
        then
            bitrates_command="-b $bitrates"
            master=1
        else
            master=0
        fi
        if [ -z "$quality" ] 
        then
            SetConst
        else
            const=$d_const
        fi
    fi

    if [ "${kind:-}" == "flv" ] 
    then
        SetFlvPush
        SetFlvPull
        output_dir_name=$(RandOutputDirName)
        playlist_name=$(RandPlaylistName)
        seg_dir_name=$d_seg_dir_name
        seg_name=$playlist_name
        seg_length=$d_seg_length
        seg_count=$d_seg_count
        encrypt=""
        encrypt_yn="no"
        key_name=$playlist_name
    else
        SetOutputDirName
        SetPlaylistName
        SetSegDirName
        SetSegName
        SetSegLength
        SetSegCount
        SetEncrypt
        if [ -n "$encrypt" ] 
        then
            SetKeyName
        else
            key_name=$playlist_name
        fi
    fi

    SetInputFlags
    SetOutputFlags
    SetChannelName

    FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
    FFMPEG="$FFMPEG_ROOT/ffmpeg"
    export FFMPEG
    FFMPEG_INPUT_FLAGS=${input_flags//\'/}
    AUDIO_CODEC=$audio_codec
    VIDEO_CODEC=$video_codec
    SEGMENT_DIRECTORY=$seg_dir_name
    FFMPEG_FLAGS=${output_flags//\'/}
    export FFMPEG_INPUT_FLAGS
    export AUDIO_CODEC
    export VIDEO_CODEC
    export SEGMENT_DIRECTORY
    export FFMPEG_FLAGS

    if [ -n "${kind:-}" ] 
    then
        if [ "$kind" == "flv" ] 
        then
            from="AddChannel"
            ( FlvStreamCreatorWithShift ) > /dev/null 2>/dev/null </dev/null & 
        else
            echo && echo -e "$error 暂不支持输出 $kind ..." && echo && exit 1
        fi
    elif [ -n "${video_audio_shift:-}" ] 
    then
        from="AddChannel"
        ( HlsStreamCreatorWithShift ) > /dev/null 2>/dev/null </dev/null &
    else
        exec "$CREATOR_FILE" -l -i "$stream_link" -s "$seg_length" \
            -o "$output_dir_root" -c "$seg_count" $bitrates_command \
            -p "$playlist_name" -t "$seg_name" -K "$key_name" $quality_command \
            "$const" "$encrypt" &
        pid=$!
        $JQ_FILE '.channels += [
            {
                "pid":'"$pid"',
                "status":"on",
                "stream_link":"'"$stream_link"'",
                "output_dir_name":"'"$output_dir_name"'",
                "playlist_name":"'"$playlist_name"'",
                "seg_dir_name":"'"$SEGMENT_DIRECTORY"'",
                "seg_name":"'"$seg_name"'",
                "seg_length":'"$seg_length"',
                "seg_count":'"$seg_count"',
                "video_codec":"'"$VIDEO_CODEC"'",
                "audio_codec":"'"$AUDIO_CODEC"'",
                "video_audio_shift":"",
                "quality":"'"$quality"'",
                "bitrates":"'"$bitrates"'",
                "const":"'"$const_yn"'",
                "encrypt":"'"$encrypt_yn"'",
                "key_name":"'"$key_name"'",
                "input_flags":"'"$FFMPEG_INPUT_FLAGS"'",
                "output_flags":"'"$FFMPEG_FLAGS"'",
                "channel_name":"'"$channel_name"'",
                "flv_status":"off",
                "flv_push_link":"",
                "flv_pull_link":""
            }
        ]' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        action="add"
        SyncFile
    fi

    echo && echo -e "$info 频道添加成功 !" && echo
}

EditStreamLink()
{
    SetStreamLink
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.stream_link)="'"$stream_link"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 直播源修改成功 !" && echo
}

EditOutputDirName()
{
    if [ "$chnl_status" == "on" ]
    then
        echo && echo -e "$error 检测到频道正在运行，是否现在关闭？[y/N]" && echo
        read -p "(默认: N):" stop_channel_yn
        stop_channel_yn=${stop_channel_yn:-'n'}
        if [[ "$stop_channel_yn" == [Yy] ]]
        then
            StopChannel
            echo && echo
        else
            echo "已取消..." && exit 1
        fi
    fi
    SetOutputDirName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.output_dir_name)="'"$output_dir_name"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 输出目录名称修改成功 !" && echo
}

EditPlaylistName()
{
    SetPlaylistName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.playlist_name)="'"$playlist_name"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info m3u8名称修改成功 !" && echo
}

EditSegDirName()
{
    SetSegDirName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.seg_dir_name)="'"$seg_dir_name"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 段所在子目录名称修改成功 !" && echo
}

EditSegName()
{
    SetSegName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.seg_name)="'"$seg_name"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 段名称修改成功 !" && echo
}

EditSegLength()
{
    SetSegLength
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.seg_length)='"$seg_length"'' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 段时长修改成功 !" && echo
}

EditSegCount()
{
    SetSegCount
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.seg_count)='"$seg_count"'' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 段数目修改成功 !" && echo
}

EditVideoCodec()
{
    SetVideoCodec
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.video_codec)="'"$video_codec"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 视频编码修改成功 !" && echo
}

EditAudioCodec()
{
    SetAudioCodec
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.audio_codec)="'"$audio_codec"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 音频编码修改成功 !" && echo
}

EditQuality()
{
    SetQuality
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.quality)="'"$quality"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info crf质量值修改成功 !" && echo
}

EditBitrates()
{
    SetBitrates
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.bitrates)="'"$bitrates"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 比特率修改成功 !" && echo
}

EditConst()
{
    SetConst
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.const)="'"$const"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 是否固定码率修改成功 !" && echo
}

EditEncrypt()
{
    SetEncrypt
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.encrypt)="'"$encrypt"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 是否加密修改成功 !" && echo
}

EditKeyName()
{
    SetKeyName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.key_name)="'"$key_name"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info key名称修改成功 !" && echo
}

EditInputFlags()
{
    SetInputFlags
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.input_flags)="'"$input_flags"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info input flags修改成功 !" && echo
}

EditOutputFlags()
{
    SetOutputFlags
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.output_flags)="'"$output_flags"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info output flags修改成功 !" && echo
}

EditChannelName()
{
    SetChannelName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.channel_name)="'"$channel_name"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 频道名称修改成功 !" && echo
}

EditChannelAll()
{
    if [ "$chnl_flv_status" == "on" ] 
    then
        kind="flv"
        echo && echo -e "$error 检测到频道正在运行，是否现在关闭？[y/N]" && echo
        read -p "(默认: N):" stop_channel_yn
        stop_channel_yn=${stop_channel_yn:-'n'}
        if [[ "$stop_channel_yn" == [Yy] ]]
        then
            StopChannel
            echo && echo
        else
            echo "已取消..." && exit 1
        fi
    elif [ "$chnl_status" == "on" ]
    then
        kind=""
        echo && echo -e "$error 检测到频道正在运行，是否现在关闭？[y/N]" && echo
        read -p "(默认: N):" stop_channel_yn
        stop_channel_yn=${stop_channel_yn:-'n'}
        if [[ "$stop_channel_yn" == [Yy] ]]
        then
            StopChannel
            echo && echo
        else
            echo "已取消..." && exit 1
        fi
    fi
    SetStreamLink
    SetOutputDirName
    SetPlaylistName
    SetSegDirName
    SetSegName
    SetSegLength
    SetSegCount
    SetVideoCodec
    SetAudioCodec
    SetVideoAudioShift
    if [ "$video_codec" == "copy" ] && [ "$audio_codec" == "copy" ]
    then
        quality=""
        bitrates=""
        const=""
        const_yn="no"
        const_text="否"
    else
        SetQuality
        SetBitrates
        if [ -z "$quality" ] 
        then
            SetConst
        else
            const=$d_const
        fi
    fi
    SetEncrypt
    if [ -n "$encrypt" ] 
    then
        SetKeyName
    else
        key_name=$playlist_name
    fi
    SetInputFlags
    SetOutputFlags
    SetChannelName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.stream_link)="'"$stream_link"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.seg_length)='"$seg_length"'|(.channels[]|select(.pid=='"$chnl_pid"')|.output_dir_name)="'"$output_dir_name"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.seg_count)='"$seg_count"'|(.channels[]|select(.pid=='"$chnl_pid"')|.video_codec)="'"$video_codec"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.audio_codec)="'"$audio_codec"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.bitrates)="'"$bitrates"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.playlist_name)="'"$playlist_name"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.channel_name)="'"$channel_name"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.seg_dir_name)="'"$seg_dir_name"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.seg_name)="'"$seg_name"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.const)="'"$const"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.quality)="'"$quality"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.encrypt)="'"$encrypt_yn"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.key_name)="'"$key_name"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.input_flags)="'"$input_flags"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.output_flags)="'"$output_flags"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 频道修改成功 !" && echo
}

EditForSecurity()
{
    SetPlaylistName
    SetSegName
    $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.playlist_name)="'"$playlist_name"'"|(.channels[]|select(.pid=='"$chnl_pid"')|.seg_name)="'"$seg_name"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
    mv "$CHANNELS_TMP" "$CHANNELS_FILE"
    echo && echo -e "$info 段名称、m3u8名称 修改成功 !" && echo
}

EditChannelMenu()
{
    ListChannels
    InputChannelsPids
    for chnl_pid in "${chnls_pids_arr[@]}"
    do
        GetChannelInfo
        ViewChannelInfo
        echo && echo -e "你要修改什么？
    ${green}1.$plain 修改 直播源
    ${green}2.$plain 修改 输出目录名称
    ${green}3.$plain 修改 m3u8名称
    ${green}4.$plain 修改 段所在子目录名称
    ${green}5.$plain 修改 段名称
    ${green}6.$plain 修改 段时长
    ${green}7.$plain 修改 段数目
    ${green}8.$plain 修改 视频编码
    ${green}9.$plain 修改 音频编码
    ${green}10.$plain 修改 crf质量值
    ${green}11.$plain 修改 比特率
    ${green}12.$plain 修改 是否固定码率
    ${green}13.$plain 修改 是否加密
    ${green}14.$plain 修改 key名称
    ${green}15.$plain 修改 input flags
    ${green}16.$plain 修改 output flags
    ${green}17.$plain 修改 频道名称
    ${green}18.$plain 修改 全部配置
    ————— 组合[常用] —————
    ${green}19.$plain 修改 段名称、m3u8名称 (防盗链/DDoS)
    " && echo
        read -p "(默认: 取消):" edit_channel_num
        [ -z "$edit_channel_num" ] && echo "已取消..." && exit 1
        case $edit_channel_num in
            1)
                EditStreamLink
            ;;
            2)
                EditOutputDirName
            ;;
            3)
                EditPlaylistName
            ;;
            4)
                EditSegDirName
            ;;
            5)
                EditSegName
            ;;
            6)
                EditSegLength
            ;;
            7)
                EditSegCount
            ;;
            8)
                EditVideoCodec
            ;;
            9)
                EditAudioCodec
            ;;
            10)
                EditQuality
            ;;
            11)
                EditBitrates
            ;;
            12)
                EditConst
            ;;
            13)
                EditEncrypt
            ;;
            14)
                EditKeyName
            ;;
            15)
                EditInputFlags
            ;;
            16)
                EditOutputFlags
            ;;
            17)
                EditChannelName
            ;;
            18)
                EditChannelAll
            ;;
            19)
                EditForSecurity
            ;;
            *)
                echo "请输入正确序号..." && exit 1
            ;;
        esac

        if [ "$chnl_status" == "on" ] || [ "$chnl_flv_status" == "on" ]
        then
            echo "是否重启此频道？[Y/n]"
            read -p "(默认: Y):" restart_yn
            restart_yn=${restart_yn:-"Y"}
            if [[ "$restart_yn" == [Yy] ]] 
            then
                StopChannel
                GetChannelInfo
                StartChannel
                echo && echo -e "$info 频道重启成功 !" && echo
            else
                echo "不重启..."
            fi
        else
            echo "是否启动此频道？[y/N]"
            read -p "(默认: N):" start_yn
            start_yn=${start_yn:-"N"}
            if [[ "$start_yn" == [Yy] ]] 
            then
                GetChannelInfo
                StartChannel
                echo && echo -e "$info 频道启动成功 !" && echo
            else
                echo "不启动..."
            fi
        fi
    done
}

ToggleChannel()
{
    ListChannels
    InputChannelsPids
    for chnl_pid in "${chnls_pids_arr[@]}"
    do
        GetChannelInfo

        if [ "${kind:-}" == "flv" ] 
        then
            if [ "$chnl_flv_status" == "on" ] 
            then
                StopChannel
            else
                StartChannel
            fi
        elif [ "$chnl_status" == "on" ] 
        then
            StopChannel
        else
            StartChannel
        fi
    done
}

StartChannel()
{
    if [[ ${chnl_stream_link:-} == *".m3u8"* ]] 
    then
        chnl_input_flags=${chnl_input_flags//-reconnect_at_eof 1/}
    elif [ "${chnl_stream_link:0:4}" == "rtmp" ] 
    then
        chnl_input_flags=${chnl_input_flags//-timeout 2000000000/}
        chnl_input_flags=${chnl_input_flags//-reconnect 1/}
        chnl_input_flags=${chnl_input_flags//-reconnect_at_eof 1/}
        chnl_input_flags=${chnl_input_flags//-reconnect_streamed 1/}
        chnl_input_flags=${chnl_input_flags//-reconnect_delay_max 2000/}
    fi
    chnl_quality_command=""
    chnl_bitrates_command=""
    if [ "$chnl_video_codec" == "copy" ] && [ "$chnl_audio_codec" == "copy" ]
    then
        chnl_quality=""
        chnl_bitrates=""
        master=0
        chnl_const=""
    else
        if [ -n "$chnl_quality" ] 
        then
            chnl_quality_command="-q $chnl_quality"
        fi
        if [ -n "$chnl_bitrates" ] 
        then
            chnl_bitrates_command="-b $chnl_bitrates"
            master=1
        else
            master=0
        fi
    fi
    FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
    FFMPEG="$FFMPEG_ROOT/ffmpeg"
    export FFMPEG
    FFMPEG_INPUT_FLAGS=${chnl_input_flags//\'/}
    AUDIO_CODEC=$chnl_audio_codec
    VIDEO_CODEC=$chnl_video_codec
    SEGMENT_DIRECTORY=$chnl_seg_dir_name
    FFMPEG_FLAGS=${chnl_output_flags//\'/}
    export FFMPEG_INPUT_FLAGS
    export AUDIO_CODEC
    export VIDEO_CODEC
    export SEGMENT_DIRECTORY
    export FFMPEG_FLAGS

    if [ -n "${kind:-}" ] 
    then
        if [ "$kind" == "flv" ] 
        then
            from="StartChannel"
            ( FlvStreamCreatorWithShift ) > /dev/null 2>/dev/null </dev/null &
        else
            echo && echo -e "$error 暂不支持输出 $kind ..." && echo && exit 1
        fi
    elif [ -n "${chnl_video_audio_shift:-}" ] 
    then
        from="StartChannel"
        ( HlsStreamCreatorWithShift ) > /dev/null 2>/dev/null </dev/null &
    elif [ -n "${monitor:-}" ] 
    then
        ( 
            trap '' HUP INT QUIT TERM
            #trap 'chnl_pid=$new_pid; StopChannel; MonitorError $LINENO' ERROR
            exec "$CREATOR_FILE" -l -i "$chnl_stream_link" -s "$chnl_seg_length" \
            -o "$chnl_output_dir_root" -c "$chnl_seg_count" $chnl_bitrates_command \
            -p "$chnl_playlist_name" -t "$chnl_seg_name" -K "$chnl_key_name" $chnl_quality_command \
            "$chnl_const" "$chnl_encrypt" &
            new_pid=$!
            $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.pid)='"$new_pid"'|(.channels[]|select(.pid=='"$new_pid"')|.status)="on"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
            mv "$CHANNELS_TMP" "$CHANNELS_FILE"
            action=${action:-"start"}
            SyncFile
        ) > /dev/null 2>/dev/null </dev/null
    else
        exec "$CREATOR_FILE" -l -i "$chnl_stream_link" -s "$chnl_seg_length" \
            -o "$chnl_output_dir_root" -c "$chnl_seg_count" $chnl_bitrates_command \
            -p "$chnl_playlist_name" -t "$chnl_seg_name" -K "$chnl_key_name" $chnl_quality_command \
            "$chnl_const" "$chnl_encrypt" &
        new_pid=$!
        $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.pid)='"$new_pid"'|(.channels[]|select(.pid=='"$new_pid"')|.status)="on"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        action=${action:-"start"}
        SyncFile
    fi

    echo && echo -e "$info 频道进程已开启 !" && echo
}

StopChannel()
{
    if [ -n "${kind:-}" ] && [ "$kind" != "flv" ]
    then
        echo -e "$error 暂不支持 $kind ..." && echo && exit 1
    fi

    stopped=0

    if kill -0 "$chnl_pid" 2> /dev/null 
    then
        while IFS= read -r ffmpeg_pid 
        do
            if [ -z "$ffmpeg_pid" ] 
            then
                if kill -9 "$chnl_pid" 2> /dev/null 
                then
                    echo && echo -e "$info 频道进程 $chnl_pid 已停止 !" && echo
                    stopped=1
                    break
                fi
            else
                while IFS= read -r real_ffmpeg_pid 
                do
                    if [ -z "$real_ffmpeg_pid" ] 
                    then
                        if kill -9 "$ffmpeg_pid" 2> /dev/null 
                        then
                            echo && echo -e "$info 频道进程 $chnl_pid 已停止 !" && echo
                            stopped=1
                            break 2
                        fi
                    elif kill -9 "$real_ffmpeg_pid" 2> /dev/null 
                    then
                        echo && echo -e "$info 频道进程 $chnl_pid 已停止 !" && echo
                        stopped=1
                        break 2
                    fi
                done <<< $(pgrep -P "$ffmpeg_pid")
            fi
        done <<< $(pgrep -P "$chnl_pid")
    else
        stopped=1
    fi

    if [ "$stopped" == 0 ] 
    then
        if [ -n "${monitor:-}" ]
        then
            return 0
        fi
        echo -e "$error 关闭频道进程 $chnl_pid 遇到错误，请重试 !" && echo && exit 1
    fi


    if [ "${kind:-}" == "flv" ] 
    then
        $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.flv_status)="off"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        action=${action:-"stop"}
        SyncFile
    else
        remove_dir_name=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').output_dir_name' "$CHANNELS_FILE")
        $JQ_FILE '(.channels[]|select(.pid=='"$chnl_pid"')|.status)="off"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        action=${action:-"stop"}
        SyncFile
        if [ ! -e "$LIVE_ROOT/${remove_dir_name:-'notfound'}" ] 
        then
            echo && echo -e "$error 找不到应该删除的目录，请手动删除 !" && echo
        else
            rm -rf "$LIVE_ROOT/${remove_dir_name:-'notfound'}"
            echo && echo -e "$info 频道目录删除成功 !" && echo
        fi
    fi
}

RestartChannel()
{
    ListChannels
    InputChannelsPids
    for chnl_pid in "${chnls_pids_arr[@]}"
    do
        GetChannelInfo
        if [ "${kind:-}" == "flv" ] 
        then
            if [ "$chnl_flv_status" == "on" ] 
            then
                action="skip"
                StopChannel
            fi
        elif [ "$chnl_status" == "on" ] 
        then
            action="skip"
            StopChannel
        fi
        StartChannel
        echo && echo -e "$info 频道重启成功 !" && echo
    done
}

DelChannel()
{
    ListChannels
    InputChannelsPids
    for chnl_pid in "${chnls_pids_arr[@]}"
    do
        chnl_status=$($JQ_FILE -r '.channels[]|select(.pid=='"$chnl_pid"').status' "$CHANNELS_FILE")
        if [ "${kind:-}" == "flv" ] 
        then
            if [ "$chnl_flv_status" == "on" ] 
            then
                StopChannel
            fi
        elif [ "$chnl_status" == "on" ] 
        then
            StopChannel
        fi
        $JQ_FILE '.channels -= [.channels[]|select(.pid=='"$chnl_pid"')]' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        echo -e "$info 频道删除成功 !" && echo
    done
}

RandStr()
{
    if [ -z ${1+x} ] 
    then
        str_size=8
    else
        str_size=$1
    fi
    str_array=(
        q w e r t y u i o p a s d f g h j k l z x c v b n m Q W E R T Y U I O P A S D
F G H J K L Z X C V B N M
    )
    str_array_size=${#str_array[*]}
    str_len=0
    rand_str=""
    while [ $str_len -lt $str_size ]
    do
        str_index=$((RANDOM%str_array_size))
        rand_str="$rand_str${str_array[$str_index]}"
        str_len=$((str_len+1))
    done
    echo "$rand_str"
}

RandOutputDirName()
{
    while :;do
        output_dir_name=$(RandStr)
        if [ -z "$($JQ_FILE '.channels[] | select(.outputDirName=="'"$output_dir_name"'")' $CHANNELS_FILE)" ]
        then
            echo "$output_dir_name"
            break
        fi
    done
}

RandPlaylistName()
{
    while :;do
        playlist_name=$(RandStr)
        if [ -z "$($JQ_FILE '.channels[] | select(.playListName=="'"$playlist_name"'")' $CHANNELS_FILE)" ]
        then
            echo "$playlist_name"
            break
        fi
    done
}

RandSegDirName()
{
    while :;do
        seg_dir_name=$(RandStr)
        if [ -z "$($JQ_FILE '.channels[] | select(.segDirName=="'"$seg_dir_name"'")' $CHANNELS_FILE)" ]
        then
            echo "$seg_dir_name"
            break
        fi
    done
}

# printf %s "$1" | jq -s -R -r @uri
urlencode() {
    local LANG=C i c e=''
    for ((i=0;i<${#1};i++)); do
        c=${1:$i:1}
        [[ "$c" =~ [a-zA-Z0-9\.\~\_\-] ]] || printf -v c '%%%02X' "'$c"
        e+="$c"
    done
    echo "$e"
}

generateScheduleNowtv()
{
    SCHEDULE_TMP_NOWTV="${SCHEDULE_JSON}_tmp"

    SCHEDULE_LINK_NOWTV="https://nowplayer.now.com/tvguide/epglist?channelIdList%5B%5D=$1&day=1"

    nowtv_schedule=$(curl --cookie "LANG=zh" -s "$SCHEDULE_LINK_NOWTV" || true)

    if [ -z "${nowtv_schedule:-}" ]
    then
        echo -e "\nNowTV empty: $chnl_nowtv_id\n"
        return 0
    else
        if [ -z "$($JQ_FILE '.' $SCHEDULE_JSON)" ] 
        then
            printf '{"%s":[]}' "$chnl_nowtv_id" > "$SCHEDULE_JSON"
        fi

        $JQ_FILE '.'"$chnl_nowtv_id"' = []' "$SCHEDULE_JSON" > "$SCHEDULE_TMP_NOWTV"
        mv "$SCHEDULE_TMP_NOWTV" "$SCHEDULE_JSON"

        schedule=""
        while IFS= read -r program
        do
            title=${program#*title: }
            title=${title%, time:*}
            time=${program#*time: }
            time=${time%, sys_time:*}
            sys_time=${program#*sys_time: }
            sys_time=${sys_time:0:10}
            [ -n "$schedule" ] && schedule="$schedule,"
            schedule=$schedule'{
                "title":"'"${title}"'",
                "time":"'"${time}"'",
                "sys_time":"'"${sys_time}"'"
            }'
        done < <($JQ_FILE -r '.[0] | to_entries | map("title: \(.value.name), time: \(.value.startTime), sys_time: \(.value.start)") | .[]' <<< "$nowtv_schedule")

        schedule="[$schedule]"

        if [ -z "$schedule" ] 
        then
            echo -e "$error\nNowTV not found\n"
        else
            $JQ_FILE --arg index "$chnl_nowtv_id" --argjson program "$schedule" '.[$index] += $program' "$SCHEDULE_JSON" > "$SCHEDULE_TMP_NOWTV"
            mv "$SCHEDULE_TMP_NOWTV" "$SCHEDULE_JSON"
        fi
    fi
}

generateScheduleNiotv()
{
    date_now_niotv=$(date -d now "+%Y-%m-%d")
    SCHEDULE_LINK_NIOTV="http://www.niotv.com/i_index.php?cont=day"
    SCHEDULE_FILE_NIOTV="$IPTV_ROOT/${chnl_niotv_id}_niotv_schedule_$date_now_niotv"
    SCHEDULE_TMP_NIOTV="${SCHEDULE_JSON}_tmp"

    wget --post-data "act=select&day=$date_now_niotv&sch_id=$1" "$SCHEDULE_LINK_NIOTV" -qO "$SCHEDULE_FILE_NIOTV" || true
    #curl -d "day=$date_now_niotv&sch_id=$1" -X POST "$SCHEDULE_LINK_NIOTV" -so "$SCHEDULE_FILE_NIOTV" || true
    
    if [ -z "$($JQ_FILE '.' $SCHEDULE_JSON)" ] 
    then
        printf '{"%s":[]}' "$chnl_niotv_id" > "$SCHEDULE_JSON"
    fi

    $JQ_FILE '.'"$chnl_niotv_id"' = []' "$SCHEDULE_JSON" > "$SCHEDULE_TMP_NIOTV"
    mv "$SCHEDULE_TMP_NIOTV" "$SCHEDULE_JSON"

    empty=1
    check=1
    while IFS= read -r line
    do
        if [[ $line == *"<td class=epg_tab_tm>"* ]] 
        then
            empty=0
            line=${line#*<td class=epg_tab_tm>}
            start_time=${line%%~*}
            end_time=${line#*~}
            end_time=${end_time%%</td>*}
        fi

        if [[ $line == *"</a></td>"* ]] 
        then
            line=${line%% </a></td>*}
            line=${line%%</a></td>*}
            title=${line#*target=_blank>}
            title=${title//\"/}
            title=${title//\'/}
            title=${title//\\/\'}
            sys_time=$(date -d "$date_now_niotv $start_time" +%s)

            start_time_num=$(date -d "$date_now_niotv $start_time" +%s)
            end_time_num=$(date -d "$date_now_niotv $end_time" +%s)

            if [ "$check" == 1 ] && [ "$start_time_num" -gt "$end_time_num" ] 
            then
                continue
            fi

            check=0

            $JQ_FILE '.'"$chnl_niotv_id"' += [
                {
                    "title":"'"${title}"'",
                    "time":"'"$start_time"'",
                    "sys_time":"'"$sys_time"'"
                }
            ]' "$SCHEDULE_JSON" > "$SCHEDULE_TMP_NIOTV"

            mv "$SCHEDULE_TMP_NIOTV" "$SCHEDULE_JSON"
        fi
    done < "$SCHEDULE_FILE_NIOTV"

    rm -rf "${SCHEDULE_FILE_NIOTV:-'notfound'}"

    if [ "$empty" == 1 ] 
    then
        echo -e "\nNioTV empty: $chnl_niotv_id\ntrying NowTV...\n"
        match_nowtv=0
        for chnl_nowtv in "${chnls_nowtv[@]}" ; do
            chnl_nowtv_id=${chnl_nowtv%%:*}
            if [ "$chnl_nowtv_id" == "$chnl_niotv_id" ] 
            then
                match_nowtv=1
                chnl_nowtv_num=${chnl_nowtv#*:}
                generateScheduleNowtv "$chnl_nowtv_num"
                break
            fi
        done
        [ "$match_nowtv" == 0 ] && echo -e "\nNowTV not found\n"
        return 0
    fi
}

generateSchedule()
{
    chnl_id=${1%%:*}
    chnl_name=${chnl#*:}
    chnl_name=${chnl_name// /-}
    chnl_name_encode=$(urlencode "$chnl_name")

    date_now=$(date -d now "+%Y-%m-%d")

    SCHEDULE_LINK="https://xn--i0yt6h0rn.tw/channel/$chnl_name_encode/index.json"
    SCHEDULE_FILE="$IPTV_ROOT/${chnl_id}_schedule_$date_now"
    SCHEDULE_TMP="${SCHEDULE_JSON}_tmp"

    wget --no-check-certificate "$SCHEDULE_LINK" -qO "$SCHEDULE_FILE" || true
    programs_count=$($JQ_FILE -r '.list[] | select(.key=="'"$date_now"'").values | length' "$SCHEDULE_FILE")
    
    if [[ $programs_count -eq 0 ]]
    then
        date_now=${date_now//-/\/}
        programs_count=$($JQ_FILE -r '.list[] | select(.key=="'"$date_now"'").values | length' "$SCHEDULE_FILE")
        if [[ $programs_count -eq 0 ]] 
        then
            echo -e "\n\nempty: $1\ntrying NioTV...\n"
            rm -rf "${SCHEDULE_FILE:-'notfound'}"
            match=0
            for chnl_niotv in "${chnls_niotv[@]}" ; do
                chnl_niotv_id=${chnl_niotv%%:*}
                if [ "$chnl_niotv_id" == "$chnl_id" ] 
                then
                    match=1
                    chnl_niotv_num=${chnl_niotv#*:}
                    generateScheduleNiotv "$chnl_niotv_num"
                fi
            done

            if [ "$match" == 0 ] 
            then
                echo -e "\nNioTV not found\ntrying NowTV...\n"
                for chnl_nowtv in "${chnls_nowtv[@]}" ; do
                    chnl_nowtv_id=${chnl_nowtv%%:*}
                    if [ "$chnl_nowtv_id" == "$chnl_id" ] 
                    then
                        match=1
                        chnl_nowtv_num=${chnl_nowtv#*:}
                        generateScheduleNowtv "$chnl_nowtv_num"
                        break
                    fi
                done
            fi

            [ "$match" == 0 ] && echo -e "\nNowTV not found\n"
            return 0
        fi
    fi

    programs_title=()
    while IFS='' read -r program_title
    do
        programs_title+=("$program_title");
    done < <($JQ_FILE -r '.list[] | select(.key=="'"$date_now"'").values | .[].name | @sh' "$SCHEDULE_FILE")

    IFS=" " read -ra programs_time <<< "$($JQ_FILE -r '[.list[] | select(.key=="'"$date_now"'").values | .[].time] | @sh' $SCHEDULE_FILE)"

    if [ -z "$($JQ_FILE '.' $SCHEDULE_JSON)" ] 
    then
        printf '{"%s":[]}' "$chnl_id" > "$SCHEDULE_JSON"
    fi

    $JQ_FILE '.'"$chnl_id"' = []' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"
    mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"

    rm -rf "${SCHEDULE_FILE:-'notfound'}"

    for((index = 0; index < "$programs_count"; index++)); do
        programs_title_index=${programs_title[index]//\"/}
        programs_title_index=${programs_title_index//\'/}
        programs_title_index=${programs_title_index//\\/\'}
        programs_time_index=${programs_time[index]//\'/}
        programs_sys_time_index=$(date -d "$date_now $programs_time_index" +%s)

        $JQ_FILE '.'"$chnl_id"' += [
            {
                "title":"'"${programs_title_index}"'",
                "time":"'"$programs_time_index"'",
                "sys_time":"'"$programs_sys_time_index"'"
            }
        ]' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"

        mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"
    done
}

Schedule()
{
    CheckRelease
    GetDefault

    if [ -n "$d_schedule_file" ] 
    then
        SCHEDULE_JSON=$d_schedule_file
    else
        echo "请先设置 schedule_file 位置！" && exit 1
    fi

    chnls=( 
#        "hbogq:HBO HD"
#        "hbohits:HBO Hits"
#        "hbosignature:HBO Signature"
#        "hbofamily:HBO Family"
#        "foxmovies:FOX MOVIES"
#        "disney:Disney"
        "tvbfc:TVB 翡翠台"
        "tvbpearl:TVB Pearl"
        "tvbj2:TVB J2"
        "tvbwxxw:TVB 互動新聞台"
        "fhwszx:凤凰卫视资讯台"
        "fhwsxg:凤凰卫视香港台"
        "fhwszw:凤凰卫视中文台"
        "xgws:香港衛視綜合台"
        "foxfamily:福斯家庭電影台"
        "hlwdy:好萊塢電影"
        "xwdy:星衛HD電影台"
        "mydy:美亞電影台"
        "mycinemaeurope:My Cinema Europe HD我的歐洲電影台"
        "ymjs:影迷數位紀實台"
        "ymdy:影迷數位電影台"
        "hyyj:華藝影劇台"
        "catchplaydy:CatchPlay電影台"
        "ccyj:采昌影劇台"
        "lxdy:LS龍祥電影"
        "cinemax:Cinemax"
        "cinemaworld:CinemaWorld"
        "axn:AXN HD"
        "channelv:Channel V國際娛樂台HD"
        "dreamworks:DREAMWORKS"
        "nickasia:Nickelodeon Asia(尼克兒童頻道)"
        "cbeebies:CBeebies"
        "babytv:Baby TV"
        "boomerang:Boomerang"
        "mykids:MY-KIDS TV"
        "dwxq:動物星球頻道"
        "eltvshyy:ELTV生活英語台"
        "ifundm:i-Fun動漫台"
        "momoqz:momo親子台"
        "cnkt:CN卡通台"
        "ffxw:非凡新聞"
        "hycj:寰宇財經台"
        "hyzh:寰宇HD綜合台"
        "hyxw:寰宇新聞台"
        "hyxw2:寰宇新聞二台"
        "aedzh:愛爾達綜合台"
        "aedyj:愛爾達影劇台"
        "jtzx:靖天資訊台"
        "jtzh:靖天綜合台"
        "jtyl:靖天育樂台"
        "jtxj:靖天戲劇台"
        "jthl:Nice TV 靖天歡樂台"
        "jtyh:靖天映畫"
        "jtgj:KLT-靖天國際台"
        "jtrb:靖天日本台"
        "jtdy:靖天電影台"
        "jtkt:靖天卡通台"
        "jyxj:靖洋戲劇台"
        "jykt:靖洋卡通台Nice Bingo"
        "lhxj:龍華戲劇"
        "lhox:龍華偶像"
        "lhyj:龍華影劇"
        "lhdy:龍華電影"
        "lhjd:龍華經典"
        "lhyp:龍華洋片"
        "lhdh:龍華動畫"
        "wszw:衛視中文台"
        "wsdy:衛視電影台"
        "gxws:國興衛視"
        "gs:公視"
        "gs2:公視2台"
        "gs3:公視3台"
        "ts:台視"
        "tszh:台視綜合台"
        "tscj:台視財經台"
        "hs:華視"
        "hsjywh:華視教育文化"
        "zs:中視"
        "zsxw:中視新聞台"
        "zsjd:中視經典台"
        "sltw:三立台灣台"
        "sldh:三立都會台"
        "slzh:三立綜合台"
        "slxj:三立戲劇台"
        "bdzh:八大綜合"
        "bddy:八大第一"
        "bdxj:八大戲劇"
        "bdyl:八大娛樂"
        "gdyl:高點育樂"
        "gdzh:高點綜合"
        "ydsdy:壹電視電影台"
        "ydszxzh:壹電視資訊綜合台"
        "wlty:緯來體育台"
        "wlxj:緯來戲劇台"
        "wlrb:緯來日本台"
        "wldy:緯來電影台"
        "wlzh:緯來綜合台"
        "wlyl:緯來育樂台"
        "wljc:緯來精采台"
        "dszh:東森綜合台"
        "dsxj:東森戲劇台"
        "dsyy:東森幼幼台"
        "dsdy:東森電影台"
        "dsyp:東森洋片台"
        "dsxw:東森新聞台"
        "dscjxw:東森財經新聞台"
        "dscs:超級電視台"
        "ztxw:中天新聞台"
        "ztyl:中天娛樂台"
        "ztzh:中天綜合台"
        "msxq:美食星球頻道"
        "yzms:亞洲美食頻道"
        "yzly:亞洲旅遊台"
        "yzzh:亞洲綜合台"
        "yzxw:亞洲新聞台"
        "pltw:霹靂台灣"
        "titvyjm:原住民"
        "history:歷史頻道"
        "history2:HISTORY 2"
        "gjdlyr:國家地理高畫質悠人頻道"
        "gjdlys:國家地理高畫質野生頻道"
        "gjdlgq:國家地理高畫質頻道"
        "bbcearth:BBC Earth"
        "bbcworldnews:BBC World News"
        "bbclifestyle:BBC Lifestyle Channel"
        "wakawakajapan:WAKUWAKU JAPAN"
        "luxe:LUXE TV Channel"
        "bswx:博斯無限台"
        "bsgq1:博斯高球一台"
        "bsgq2:博斯高球二台"
        "bsml:博斯魅力網"
        "bswq:博斯網球台"
        "bsyd1:博斯運動一台"
        "bsyd2:博斯運動二台"
        "zlty:智林體育台"
        "eurosport:EUROSPORT"
        "fox:FOX頻道"
        "foxsports:FOX SPORTS"
        "foxsports2:FOX SPORTS 2"
        "foxsports3:FOX SPORTS 3"
        "elevensportsplus:ELEVEN SPORTS PLUS"
        "elevensports2:ELEVEN SPORTS 2"
        "discoveryasia:Discovery Asia"
        "discovery:Discovery"
        "discoverykx:Discovery科學頻道"
        "tracesportstars:TRACE Sport Stars"
        "dw:DW(Deutsch)"
        "lifetime:Lifetime"
        "foxcrime:FOXCRIME"
        "foxnews:FOX News Channel"
        "animax:Animax"
        "mtv:MTV綜合電視台"
        "ndmuch:年代MUCH"
        "ndxw:年代新聞"
        "nhk:NHK"
        "euronews:Euronews"
        "cnn:CNN International"
        "skynews:SKY NEWS HD"
        "nhkxwzx:NHK新聞資訊台"
        "jetzh:JET綜合"
        "tlclysh:旅遊生活"
        "z:Z頻道"
        "itvchoice:ITV Choice"
        "mdrb:曼迪日本台"
        "smartzs:Smart知識台"
        "tv5monde:TV5MONDE"
        "outdoor:Outdoor"
        "eentertainment:E! Entertainment"
        "davinci:DaVinCi Learning達文西頻道"
        "my101zh:MY101綜合台"
        "blueantextreme:BLUE ANT EXTREME"
        "blueantentertainmet:BLUE ANT EXTREME"
        "eyetvxj:EYE TV戲劇台"
        "eyetvly:EYE TV旅遊台"
        "travel:Travel Channel"
        "dmax:DMAX頻道"
        "hitshd:HITS"
        "fx:FX"
        "tvbs:TVBS"
        "tvbshl:TVBS歡樂"
        "tvbsjc:TVBS精采台"
        "tvbxh:TVB星河頻道"
        "tvn:tvN"
        "hgyl:韓國娛樂台KMTV"
        "xfkjjj:幸福空間居家台"
        "xwyl:星衛娛樂台"
        "amc:AMC"
        "animaxhd:Animax HD"
        "diva:Diva"
        "bloomberg:Bloomberg TV"
        "fgss:時尚頻道"
        "warner:Warner TV"
        "ettodayzh:ETtoday綜合台" )

    chnls_niotv=( 
        "hbogq:629"
        "hbohits:501"
        "hbosignature:503"
        "hbofamily:502"
        "foxmovies:47"
        "foxfamily:540"
        "disney:63"
        "dreamworks:758"
        "nickasia:705"
        "cbeebies:771"
        "babytv:553"
        "boomerang:766"
        "dwxq:61"
        "momoqz:148"
        "cnkt:65"
        "hyxw:695"
        "jtzx:709"
        "jtzh:710"
        "jtyl:202"
        "jtxj:721"
        "jthl:708"
        "jtyh:727"
        "jtrb:711"
        "jtkt:707"
        "jyxj:203"
        "jykt:706"
        "wszw:19"
        "wsdy:55"
        "gxws:73"
        "gs:17"
        "gs2:759"
        "gs3:177"
        "ts:11"
        "tszh:632"
        "tscj:633"
        "hs:15"
        "hsjywh:138"
        "zs:13"
        "zsxw:668"
        "zsjd:714"
        "sltw:34"
        "sldh:35"
        "bdzh:21"
        "bddy:33"
        "bdxj:22"
        "bdyl:60"
        "gdyl:170"
        "gdzh:143"
        "ydsdy:187"
        "ydszxzh:681"
        "wlty:66"
        "wlxj:29"
        "wlrb:72"
        "wldy:57"
        "wlzh:24"
        "wlyl:53"
        "wljc:546"
        "dszh:23"
        "dsxj:36"
        "dsyy:64"
        "dsdy:56"
        "dsyp:48"
        "dsxw:42"
        "dscjxw:43"
        "dscs:18"
        "ztxw:668"
        "ztyl:14"
        "ztzh:27"
        "yzly:778"
        "yzms:733"
        "yzxw:554"
        "pltw:26"
        "titvyjm:133"
        "history:549"
        "history2:198"
        "gjdlyr:670"
        "gjdlys:161"
        "gjdlgq:519"
        "discoveryasia:563"
        "discovery:58"
        "discoverykx:520"
        "bbcearth:698"
        "bbcworldnews:144"
        "bbclifestyle:646"
        "bswx:587"
        "bsgq1:529"
        "bsgq2:526"
        "bsml:588"
        "bsyd2:635"
        "bsyd1:527"
        "eurosport:581"
        "fox:70"
        "foxsports:67"
        "foxsports2:68"
        "foxsports3:547"
        "elevensportsplus:787"
        "elevensports2:770"
        "lifetime:199"
        "foxcrime:543"
        "cinemax:49"
        "hlwdy:52"
        "animax:84"
        "mtv:69"
        "ndmuch:25"
        "ndxw:40"
        "nhk:74"
        "euronews:591"
        "ffxw:79"
        "jetzh:71"
        "tlclysh:62"
        "axn:50"
        "z:75"
        "luxe:590"
        "catchplaydy:582"
        "tv5monde:574"
        "channelv:584"
        "davinci:669"
        "blueantextreme:779"
        "blueantentertainmet:785"
        "travel:684"
        "cnn:107"
        "dmax:521"
        "hitshd:692"
        "lxdy:141"
        "fx:544"
        "tvn:757"
        "hgyl:568"
        "xfkjjj:672"
        "nhkxwzx:773"
        "zlty:676"
        "xwdy:558"
        "xwyl:539"
        "mycinemaeurope:775"
        "amc:682"
        "animaxhd:772"
        "wakawakajapan:765"
        "tvbs:20"
        "tvbshl:32"
        "tvbsjc:774"
        "cinemaworld:559"
        "warner:688" )

    chnls_nowtv=( 
        "hbohits:111"
        "hbofamily:112"
        "cinemax:113"
        "hbosignature:114"
        "hbogq:115"
        "foxmovies:117"
        "foxfamily:120"
        "foxaction:118"
        "wsdy:139"
        "animaxhd:150"
        "tvn:155"
        "wszw:160"
        "discoveryasia:208"
        "discovery:209"
        "dwxq:210"
        "discoverykx:211"
        "dmax:212"
        "tlclysh:213"
        "gjdl:215"
        "gjdlys:216"
        "gjdlyr:217"
        "gjdlgq:218"
        "bbcearth:220"
        "history:223"
        "cnn:316"
        "foxnews:318"
        "bbcworldnews:320"
        "bloomberg:321"
        "yzxw:322"
        "skynews:323"
        "dw:324"
        "euronews:326"
        "nhk:328"
        "fhwszx:366"
        "fhwsxg:367"
        "xgws:368"
        "disney:441"
        "boomerang:445"
        "cbeebies:447"
        "babytv:448"
        "bbclifestyle:502"
        "eentertainment:506"
        "diva:508"
        "warner:510"
        "AXN:512"
        "blueantextreme:516"
        "blueantentertainmet:517"
        "fox:518"
        "foxcrime:523"
        "fx:524"
        "lifetime:525"
        "yzms:527"
        "channelv:534"
        "fhwszw:548"
        "zgzwws:556"
        "foxsports:670"
        "foxsports2:671"
        "foxsports3:672" )

    if [ -z ${2+x} ] 
    then
        count=0

        for chnl in "${chnls[@]}" ; do
            generateSchedule "$chnl"
            count=$((count + 1))
            echo -n $count
        done

        return
    fi

    case $2 in
        "hbo")
            date_now=$(date -d now "+%Y-%m-%d")

            chnls=(
                "hbo"
                "hbotw"
                "hbored"
                "hbohd"
                "hits"
                "signature"
                "family" )

            for chnl in "${chnls[@]}" ; do

                if [ "$chnl" == "hbo" ] 
                then
                    SCHEDULE_LINK="https://hboasia.com/HBO/zh-cn/ajax/home_schedule?date=$date_now&channel=$chnl&feed=cn"
                elif [ "$chnl" == "hbotw" ] 
                then
                    SCHEDULE_LINK="https://hboasia.com/HBO/zh-cn/ajax/home_schedule?date=$date_now&channel=hbo&feed=satellite"
                elif [ "$chnl" == "hbored" ] 
                then
                    SCHEDULE_LINK="https://hboasia.com/HBO/zh-cn/ajax/home_schedule?date=$date_now&channel=red&feed=satellite"
                else
                    SCHEDULE_LINK="https://hboasia.com/HBO/zh-tw/ajax/home_schedule?date=$date_now&channel=$chnl&feed=satellite"
                fi
                
                SCHEDULE_FILE="$IPTV_ROOT/${chnl}_schedule_$date_now"
                SCHEDULE_TMP="${SCHEDULE_JSON}_tmp"
                wget --no-check-certificate "$SCHEDULE_LINK" -qO "$SCHEDULE_FILE"
                programs_count=$($JQ_FILE -r '. | length' "$SCHEDULE_FILE")

                programs_title=()
                while IFS='' read -r program_title
                do
                    programs_title+=("$program_title");
                done < <($JQ_FILE -r '.[].title | @sh' "$SCHEDULE_FILE")

                programs_title_local=()
                while IFS='' read -r program_title_local
                do
                    programs_title_local+=("$program_title_local");
                done < <($JQ_FILE -r '.[].title_local | @sh' "$SCHEDULE_FILE")

                IFS=" " read -ra programs_id <<< "$($JQ_FILE -r '[.[].id] | @sh' $SCHEDULE_FILE)"
                IFS=" " read -ra programs_time <<< "$($JQ_FILE -r '[.[].time] | @sh' $SCHEDULE_FILE)"
                IFS=" " read -ra programs_sys_time <<< "$($JQ_FILE -r '[.[].sys_time] | @sh' $SCHEDULE_FILE)"

                if [ -z "$($JQ_FILE '.' $SCHEDULE_JSON)" ] 
                then
                    printf '{"%s":[]}' "$chnl" > "$SCHEDULE_JSON"
                fi

                $JQ_FILE '.'"$chnl"' = []' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"
                mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"

                rm -rf "${SCHEDULE_FILE:-'notfound'}"

                for((index = 0; index < "$programs_count"; index++)); do
                    programs_id_index=${programs_id[index]//\'/}
                    programs_title_index=${programs_title[index]//\"/}
                    programs_title_index=${programs_title_index//\'/}
                    programs_title_index=${programs_title_index//\\/\'}
                    programs_title_local_index=${programs_title_local[index]//\"/}
                    programs_title_local_index=${programs_title_local_index//\'/}
                    programs_title_local_index=${programs_title_local_index//\\/\'}
                    if [ -n "$programs_title_local_index" ] 
                    then
                        programs_title_index="$programs_title_local_index $programs_title_index"
                    fi
                    programs_time_index=${programs_time[index]//\'/}
                    programs_sys_time_index=${programs_sys_time[index]//\'/}

                    $JQ_FILE '.'"$chnl"' += [
                        {
                            "id":"'"${programs_id_index}"'",
                            "title":"'"${programs_title_index}"'",
                            "time":"'"$programs_time_index"'",
                            "sys_time":"'"$programs_sys_time_index"'"
                        }
                    ]' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"

                    mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"
                done
            done
        ;;
        "disney")
            date_now=$(date -d now "+%Y%m%d")
            SCHEDULE_LINK="https://disney.com.tw/_schedule/full/$date_now/8/%2Fepg"

            SCHEDULE_FILE="$IPTV_ROOT/$2_schedule_$date_now"
            SCHEDULE_TMP="${SCHEDULE_JSON}_tmp"
            wget --no-check-certificate "$SCHEDULE_LINK" -qO "$SCHEDULE_FILE"

            programs_title=()
            while IFS='' read -r program_title
            do
                programs_title+=("$program_title");
            done < <($JQ_FILE -r '.schedule[].schedule_items[].show_title | @sh' "$SCHEDULE_FILE")

            programs_count=${#programs_title[@]}

            IFS=" " read -ra programs_time <<< "$($JQ_FILE -r '[.schedule[].schedule_items[].time] | @sh' $SCHEDULE_FILE)"
            IFS=" " read -ra programs_sys_time <<< "$($JQ_FILE -r '[.schedule[].schedule_items[].iso8601_utc_time] | @sh' $SCHEDULE_FILE)"

            if [ -z "$($JQ_FILE '.' $SCHEDULE_JSON)" ] 
            then
                printf '{"%s":[]}' "$2" > "$SCHEDULE_JSON"
            fi

            $JQ_FILE '.'"$2"' = []' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"
            mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"

            rm -rf "${SCHEDULE_FILE:-'notfound'}"

            for((index = 0; index < "$programs_count"; index++)); do
                programs_title_index=${programs_title[index]//\"/}
                programs_title_index=${programs_title_index//\'/}
                programs_title_index=${programs_title_index//\\/\'}
                programs_time_index=${programs_time[index]//\'/}
                programs_sys_time_index=${programs_sys_time[index]//\'/}
                programs_sys_time_index=$(date -d "$programs_sys_time_index" +%s)

                $JQ_FILE '.'"$2"' += [
                    {
                        "title":"'"${programs_title_index}"'",
                        "time":"'"$programs_time_index"'",
                        "sys_time":"'"$programs_sys_time_index"'"
                    }
                ]' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"

                mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"
            done
        ;;
        "foxmovies")
            date_now=$(date -d now "+%Y-%-m-%-d")
            SCHEDULE_LINK="https://www.fng.tw/foxmovies/program.php?go=$date_now"

            SCHEDULE_FILE="$IPTV_ROOT/$2_schedule_$date_now"
            SCHEDULE_TMP="${SCHEDULE_JSON}_tmp"
            wget --no-check-certificate "$SCHEDULE_LINK" -qO "$SCHEDULE_FILE"

            if [ -z "$($JQ_FILE '.' $SCHEDULE_JSON)" ] 
            then
                printf '{"%s":[]}' "$2" > "$SCHEDULE_JSON"
            fi

            $JQ_FILE '.'"$2"' = []' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"
            mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"

            while IFS= read -r line
            do
                if [[ $line == *"<td>"* ]] 
                then
                    line=${line#*<td>}
                    line=${line%%<\/td>*}

                    if [[ $line == *"<br>"* ]]  
                    then
                        line=${line%% <br>*}
                        line=${line//\"/}
                        line=${line//\'/}
                        line=${line//\\/\'}
                        sys_time=$(date -d "$date_now $time" +%s)
                        $JQ_FILE '.'"$2"' += [
                            {
                                "title":"'"${line}"'",
                                "time":"'"$time"'",
                                "sys_time":"'"$sys_time"'"
                            }
                        ]' "$SCHEDULE_JSON" > "$SCHEDULE_TMP"

                        mv "$SCHEDULE_TMP" "$SCHEDULE_JSON"
                    else
                        time=${line#* }
                    fi
                fi
            done < "$SCHEDULE_FILE"

            rm -rf "${SCHEDULE_FILE:-'notfound'}"
        ;;
        *) 
            found=0
            for chnl in "${chnls[@]}" ; do
                chnl_id=${chnl%%:*}
                if [ "$chnl_id" == "$2" ] 
                then
                    found=1
                    generateSchedule "$2"
                fi
            done

            if [ "$found" == 0 ] 
            then
                echo -e "\nnot found: $2\ntrying NioTV...\n"
                for chnl_niotv in "${chnls_niotv[@]}" ; do
                    chnl_niotv_id=${chnl_niotv%%:*}
                    if [ "$chnl_niotv_id" == "$2" ] 
                    then
                        found=1
                        chnl_niotv_num=${chnl_niotv#*:}
                        generateScheduleNiotv "$chnl_niotv_num"
                    fi
                done
            fi

            if [ "$found" == 0 ] 
            then
                echo -e "\nNioTV not found: $2\ntrying NowTV...\n"
                for chnl_nowtv in "${chnls_nowtv[@]}" ; do
                    chnl_nowtv_id=${chnl_nowtv%%:*}
                    if [ "$chnl_nowtv_id" == "$2" ] 
                    then
                        found=1
                        chnl_nowtv_num=${chnl_nowtv#*:}
                        generateScheduleNowtv "$chnl_nowtv_num"
                        break
                    fi
                done
            fi

            [ "$found" == 0 ] && echo "no support yet ~"
        ;;
    esac
}

TsIsUnique()
{
    not_unique=$(wget --no-check-certificate "${ts_array[unique_url]}?accounttype=${ts_array[acc_type_reg]}&username=$account" -qO- | $JQ_FILE '.ret')
    if [ "$not_unique" != 0 ] 
    then
        echo && echo -e "$error 用户名已存在,请重新输入！"
    fi
}

TsImg()
{
    IMG_FILE="$IPTV_ROOT/ts_yzm.jpg"
    if [ -n "${ts_array[refresh_token_url]:-}" ] 
    then
        str1=$(RandStr)
        str2=$(RandStr 4)
        str3=$(RandStr 4)
        str4=$(RandStr 4)
        str5=$(RandStr 12)
        deviceno="$str1-$str2-$str3-$str4-$str5"
        str6=$(printf '%s' "$deviceno" | md5sum)
        str6=${str6%% *}
        str6=${str6:7:1}
        deviceno="$deviceno$str6"
        declare -A token_array
        while IFS="=" read -r key value
        do
            token_array[$key]="$value"
        done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(curl -X POST -s --data '{"role":"guest","deviceno":"'"$deviceno"'","deviceType":"yuj"}' "${ts_array[token_url]}"))

        if [ "${token_array[ret]}" == 0 ] 
        then
            declare -A refresh_token_array
            while IFS="=" read -r key value
            do
                refresh_token_array[$key]="$value"
            done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(curl -X POST -s --data '{"accessToken":"'"${token_array[accessToken]}"'","refreshToken":"'"${token_array[refreshToken]}"'"}' "${ts_array[refresh_token_url]}"))

            if [ "${refresh_token_array[ret]}" == 0 ] 
            then
                declare -A img_array
                while IFS="=" read -r key value
                do
                    img_array[$key]="$value"
                done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(wget --no-check-certificate "${ts_array[img_url]}?accesstoken=${refresh_token_array[accessToken]}" -qO-))

                if [ "${img_array[ret]}" == 0 ] 
                then
                    picid=${img_array[picid]}
                    image=${img_array[image]}
                    refresh_img=0
                    base64 -d <<< "${image#*,}" > "$IMG_FILE"
                    imgcat --half-height "$IMG_FILE"
                    rm -rf "${IMG_FILE:-notfound}"
                    echo && echo -e "$info 输入图片验证码："
                    read -p "(默认: 刷新验证码):" pincode
                    [ -z "$pincode" ] && refresh_img=1
                    return 0
                fi
            fi
        fi
    else
        declare -A token_array
        while IFS="=" read -r key value
        do
            token_array[$key]="$value"
        done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(curl -X POST -s --data '{"usagescen":1}' "${ts_array[token_url]}"))

        if [ "${token_array[ret]}" == 0 ] 
        then
            declare -A img_array
            while IFS="=" read -r key value
            do
                img_array[$key]="$value"
            done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(wget --no-check-certificate "${ts_array[img_url]}?accesstoken=${token_array[access_token]}" -qO-))

            if [ "${img_array[ret]}" == 0 ] 
            then
                picid=${img_array[picid]}
                image=${img_array[image]}
                refresh_img=0
                base64 -d <<< "${image#*,}" > "$IMG_FILE"
                imgcat --half-height "$IMG_FILE"
                rm -rf "${IMG_FILE:-notfound}"
                echo && echo -e "$info 输入图片验证码："
                read -p "(默认: 刷新验证码):" pincode
                [ -z "$pincode" ] && refresh_img=1
                return 0
            fi
        fi
    fi
}

TsRegister()
{
    if [ ! -e "/usr/local/bin/imgcat" ] &&  [ -n "${ts_array[img_url]:-}" ]
    then
        echo -e "$error 请先安装 imgcat (https://github.com/eddieantonio/imgcat#build)" && exit 1
    fi
    not_unique=1
    while [ "$not_unique" != 0 ] 
    do
        echo && echo -e "$info 输入账号："
        read -p "(默认: 取消):" account
        [ -z "$account" ] && echo "已取消..." && exit 1
        if [ -z "${ts_array[unique_url]:-}" ] 
        then
            not_unique=0
        else
            TsIsUnique
        fi
    done

    echo && echo -e "$info 输入密码："
    read -p "(默认: 取消):" password
    [ -z "$password" ] && echo "已取消..." && exit 1

    if [ -n "${ts_array[img_url]:-}" ] 
    then
        refresh_img=1
        while [ "$refresh_img" != 0 ] 
        do
            TsImg
            [ "$refresh_img" == 1 ] && continue

            if [ -n "${ts_array[sms_url]:-}" ] 
            then
                declare -A sms_array
                while IFS="=" read -r key value
                do
                    sms_array[$key]="$value"
                done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(wget --no-check-certificate "${ts_array[sms_url]}?pincode=$pincode&picid=$picid&verifytype=3&account=$account&accounttype=1" -qO-))

                if [ "${sms_array[ret]}" == 0 ] 
                then
                    echo && echo -e "$info 短信已发送！"
                    echo && echo -e "$info 输入短信验证码："
                    read -p "(默认: 取消):" smscode
                    [ -z "$smscode" ] && echo "已取消..." && exit 1

                    declare -A verify_array
                    while IFS="=" read -r key value
                    do
                        verify_array[$key]="$value"
                    done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(wget --no-check-certificate "${ts_array[verify_url]}?verifycode=$smscode&verifytype=3&username=$account&account=$account" -qO-))

                    if [ "${verify_array[ret]}" == 0 ] 
                    then
                        str1=$(RandStr)
                        str2=$(RandStr 4)
                        str3=$(RandStr 4)
                        str4=$(RandStr 4)
                        str5=$(RandStr 12)
                        deviceno="$str1-$str2-$str3-$str4-$str5"
                        str6=$(printf '%s' "$deviceno" | md5sum)
                        str6=${str6%% *}
                        str6=${str6:7:1}
                        deviceno="$deviceno$str6"
                        devicetype="yuj"
                        md5_password=$(printf '%s' "$password" | md5sum)
                        md5_password=${md5_password%% *}
                        timestamp=$(date +%s)
                        timestamp=$((timestamp * 1000))
                        signature="$account|$md5_password|$deviceno|$devicetype|$timestamp"
                        signature=$(printf '%s' "$signature" | md5sum)
                        signature=${signature%% *}
                        declare -A reg_array
                        while IFS="=" read -r key value
                        do
                            reg_array[$key]="$value"
                        done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(curl -X POST -s --data '{"account":"'"$account"'","deviceno":"'"$deviceno"'","devicetype":"'"$devicetype"'","code":"'"${verify_array[code]}"'","signature":"'"$signature"'","birthday":"1970-1-1","username":"'"$account"'","type":1,"timestamp":"'"$timestamp"'","pwd":"'"$md5_password"'","accounttype":"'"${ts_array[acc_type_reg]}"'"}' "${ts_array[reg_url]}"))

                        if [ "${reg_array[ret]}" == 0 ] 
                        then
                            echo && echo -e "$info 注册成功！"
                            echo && echo -e "$info 是否登录账号? [y/N]" && echo
                            read -p "(默认: N):" login_yn
                            login_yn=${login_yn:-"N"}
                            if [[ "$login_yn" == [Yy] ]]
                            then
                                TsLogin
                            else
                                echo "已取消..." && exit 1
                            fi
                        else
                            echo && echo -e "$error 注册失败！"
                            printf '%s\n' "${reg_array[@]}"
                        fi
                    fi

                else
                    if [ -z "${ts_array[unique_url]:-}" ] 
                    then
                        echo && echo -e "$error 验证码或其它错误！请重新尝试！"
                    else
                        echo && echo -e "$error 验证码错误！"
                    fi
                    #printf '%s\n' "${sms_array[@]}"
                    refresh_img=1
                fi
            fi
        done
    else
        md5_password=$(printf '%s' "$password" | md5sum)
        md5_password=${md5_password%% *}
        declare -A reg_array
        while IFS="=" read -r key value
        do
            reg_array[$key]="$value"
        done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(wget --no-check-certificate "${ts_array[reg_url]}?username=$account&iconid=1&pwd=$md5_password&birthday=1970-1-1&type=1&accounttype=${ts_array[acc_type_reg]}" -qO-))

        if [ "${reg_array[ret]}" == 0 ] 
        then
            echo && echo -e "$info 注册成功！"
            echo && echo -e "$info 是否登录账号? [y/N]" && echo
            read -p "(默认: N):" login_yn
            login_yn=${login_yn:-"N"}
            if [[ "$login_yn" == [Yy] ]]
            then
                TsLogin
            else
                echo "已取消..." && exit 1
            fi
        else
            echo && echo -e "$error 发生错误"
            printf '%s\n' "${sms_array[@]}"
        fi
    fi
    
}

TsLogin()
{
    if [ -z "${account:-}" ] 
    then
        echo && echo -e "$info 输入账号："
        read -p "(默认: 取消):" account
        [ -z "$account" ] && echo "已取消..." && exit 1
    fi

    if [ -z "${password:-}" ] 
    then
        echo && echo -e "$info 输入密码："
        read -p "(默认: 取消):" password
        [ -z "$password" ] && echo "已取消..." && exit 1
    fi

    str1=$(RandStr)
    str2=$(RandStr 4)
    str3=$(RandStr 4)
    str4=$(RandStr 4)
    str5=$(RandStr 12)
    deviceno="$str1-$str2-$str3-$str4-$str5"
    str6=$(printf '%s' "$deviceno" | md5sum)
    str6=${str6%% *}
    str6=${str6:7:1}
    deviceno="$deviceno$str6"
    md5_password=$(printf '%s' "$password" | md5sum)
    md5_password=${md5_password%% *}

    if [ -z "${ts_array[img_url]:-}" ] 
    then
        TOKEN_LINK="${ts_array[login_url]}?deviceno=$deviceno&devicetype=3&accounttype=${ts_array[acc_type_login]:-2}&accesstoken=(null)&account=$account&pwd=$md5_password&isforce=1&businessplatform=1"
        token=$(wget --no-check-certificate "$TOKEN_LINK" -qO-)
    else
        timestamp=$(date +%s)
        timestamp=$((timestamp * 1000))
        signature="$deviceno|yuj|${ts_array[acc_type_login]}|$account|$timestamp"
        signature=$(printf '%s' "$signature" | md5sum)
        signature=${signature%% *}
        if [[ ${ts_array[extend_info]} == "{"*"}" ]] 
        then
            token=$(curl -X POST -s --data '{"account":"'"$account"'","deviceno":"'"$deviceno"'","pwd":"'"$md5_password"'","devicetype":"yuj","businessplatform":1,"signature":"'"$signature"'","isforce":1,"extendinfo":'"${ts_array[extend_info]}"',"timestamp":"'"$timestamp"'","accounttype":'"${ts_array[acc_type_login]}"'}' "${ts_array[login_url]}")
        else
            token=$(curl -X POST -s --data '{"account":"'"$account"'","deviceno":"'"$deviceno"'","pwd":"'"$md5_password"'","devicetype":"yuj","businessplatform":1,"signature":"'"$signature"'","isforce":1,"extendinfo":"'"${ts_array[extend_info]}"'","timestamp":"'"$timestamp"'","accounttype":'"${ts_array[acc_type_login]}"'}' "${ts_array[login_url]}")
        fi
    fi

    declare -A login_array
    while IFS="=" read -r key value
    do
        login_array[$key]="$value"
    done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< "$token")

    if [ -z "${login_array[access_token]:-}" ] 
    then
        echo -e "$error 账号错误"
        printf '%s\n' "${login_array[@]}"
        echo && echo -e "$info 是否注册账号? [y/N]" && echo
        read -p "(默认: N):" register_yn
        register_yn=${register_yn:-"N"}
        if [[ "$register_yn" == [Yy] ]]
        then
            TsRegister
        else
            echo "已取消..." && exit 1
        fi
    else
        while :; do
            echo && echo -e "$info 输入需要转换的频道号码："
            read -p "(默认: 取消):" programid
            [ -z "$programid" ] && echo "已取消..." && exit 1
            [[ $programid =~ ^[0-9]{10}$ ]] || { echo -e "$error频道号码错误！"; continue; }
            break
        done

        if [ -n "${ts_array[auth_info_url]:-}" ] 
        then
            declare -A auth_info_array
            while IFS="=" read -r key value
            do
                auth_info_array[$key]="$value"
            done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(wget --no-check-certificate "${ts_array[auth_info_url]}?accesstoken=${login_array[access_token]}&programid=$programid&playtype=live&protocol=hls&verifycode=${login_array[device_id]}" -qO-))

            if [ "${auth_info_array[ret]}" == 0 ] 
            then
                authtoken="ipanel123#%#&*(&(*#*&^*@#&*%()#*()$)#@&%(*@#()*%321ipanel${auth_info_array[auth_random_sn]}"
                authtoken=$(printf '%s' "$authtoken" | md5sum)
                authtoken=${authtoken%% *}
                playtoken=${auth_info_array[play_token]}

                declare -A auth_verify_array
                while IFS="=" read -r key value
                do
                    auth_verify_array[$key]="$value"
                done < <($JQ_FILE -r 'to_entries | map("\(.key)=\(.value)") | .[]' <<< $(wget --no-check-certificate "${ts_array[auth_verify_url]}?programid=$programid&playtype=live&protocol=hls&accesstoken=${login_array[access_token]}&verifycode=${login_array[device_id]}&authtoken=$authtoken" -qO-))

                if [ "${auth_verify_array[ret]}" == 0 ] 
                then
                    TS_LINK="${ts_array[play_url]}?playtype=live&protocol=ts&accesstoken=${login_array[access_token]}&playtoken=$playtoken&verifycode=${login_array[device_id]}&rate=org&programid=$programid"
                else
                    echo && echo -e "$error 发生错误"
                    printf '%s\n' "${auth_verify_array[@]}"
                    exit 1
                fi
            else
                echo && echo -e "$error 发生错误"
                printf '%s\n' "${auth_info_array[@]}"
                exit 1
            fi
        else
            TS_LINK="${ts_array[play_url]}?playtype=live&protocol=ts&accesstoken=${login_array[access_token]}&playtoken=ABCDEFGH&verifycode=${login_array[device_id]}&rate=org&programid=$programid"
        fi

        echo && echo -e "$info ts链接：\n$TS_LINK"

        stream_link=$($JQ_FILE -r --arg a "programid=$programid" '[.channels[].stream_link] | map(select(test($a)))[0]' "$CHANNELS_FILE")
        if [ -n "$stream_link" ] 
        then
            echo && echo -e "$info 检测到此频道原有链接，是否替换成新的ts链接? [Y/n]"
            read -p "(默认: Y):" change_yn
            change_yn=${change_yn:-"Y"}
            if [[ "$change_yn" == [Yy] ]]
            then
                $JQ_FILE '(.channels[]|select(.stream_link=="'"$stream_link"'")|.stream_link)="'"$TS_LINK"'"' "$CHANNELS_FILE" > "$CHANNELS_TMP"
                mv "$CHANNELS_TMP" "$CHANNELS_FILE"
                echo && echo -e "$info 修改成功 !" && echo
            else
                echo "已取消..." && exit 1
            fi
        fi
    fi
}

TsMenu()
{
    GetDefault

    if [ -n "$d_sync_file" ] 
    then
        local_channels=$($JQ_FILE -r '.data[] | select(.reg_url != null)' "$d_sync_file")
    fi

    echo && echo -e "$info 是否使用默认频道文件? 默认链接: $DEFAULT_CHANNELS_LINK [Y/n]" && echo
    read -p "(默认: Y):" use_default_channels_yn
    use_default_channels_yn=${use_default_channels_yn:-"Y"}
    if [[ "$use_default_channels_yn" == [Yy] ]]
    then
        TS_CHANNELS_LINK=$DEFAULT_CHANNELS_LINK
    else
        if [ -n "$local_channels" ] 
        then
            echo && echo -e "$info 是否使用本地频道文件? 本地路径: $d_sync_file [Y/n]" && echo
            read -p "(默认: Y):" use_local_channels_yn
            use_local_channels_yn=${use_local_channels_yn:-"Y"}
            if [[ "$use_local_channels_yn" == [Yy] ]] 
            then
                TS_CHANNELS_FILE=$d_sync_file
            fi
        fi
        if [ -z "${TS_CHANNELS_FILE:-}" ]
        then
            echo && echo -e "$info 请输入使用的频道文件链接或本地路径: " && echo
            read -p "(默认: 取消):" TS_CHANNELS_LINK_OR_FILE
            [ -z "$TS_CHANNELS_LINK_OR_FILE" ] && echo "已取消..." && exit 1
            if [ "${TS_CHANNELS_LINK_OR_FILE:0:4}" == "http" ] 
            then
                TS_CHANNELS_LINK=$TS_CHANNELS_LINK_OR_FILE
            else
                [ ! -e "$TS_CHANNELS_LINK_OR_FILE" ] && echo "文件不存在，已取消..." && exit 1
                TS_CHANNELS_FILE=$TS_CHANNELS_LINK_OR_FILE
            fi
        fi
    fi

    if [ -z "${TS_CHANNELS_LINK:-}" ] 
    then
        ts_channels=$(< "$TS_CHANNELS_FILE")
    else
        ts_channels=$(wget --no-check-certificate "$TS_CHANNELS_LINK" -qO-)

        [ -z "$ts_channels" ] && echo && echo -e "$error无法连接文件地址，已取消..." && exit 1
    fi

    ts_channels_desc=()
    while IFS='' read -r desc 
    do
        ts_channels_desc+=("$desc")
    done < <($JQ_FILE -r '.data[] | select(.reg_url != null) | .desc | @sh' <<< "$ts_channels")
    
    count=${#ts_channels_desc[@]}

    echo && echo -e "$info 选择需要操作的直播源"
    for((i=0;i<count;i++));
    do
        desc=${ts_channels_desc[$i]//\"/}
        desc=${desc//\'/}
        desc=${desc//\\/\'}
        echo -e "${green}$((i+1)).$plain ${desc}"
    done
    
    while :; do
        read -p "(默认: 取消):" channel_id
        [ -z "$channel_id" ] && echo "已取消..." && exit 1
        [[ $channel_id =~ ^[0-9]+$ ]] || { echo -e "$error请输入序号！"; continue; }
        if ((channel_id >= 1 && channel_id <= count)); then
            ((channel_id--))
            declare -A ts_array
            while IFS="=" read -r key value
            do
                ts_array[$key]="$value"
            done < <($JQ_FILE -r '[.data[] | select(.reg_url != null)]['"$channel_id"'] | to_entries | map("\(.key)=\(.value)") | .[]' <<< "$ts_channels")

            if [ "${ts_array[name]}" == "jxtvnet" ] && ! nc -z "access.jxtvnet.tv" 81 2>/dev/null
            then
                echo && echo -e "$info 部分服务器无法连接此直播源，但可以将ip写入 /etc/hosts 来连接，请选择线路
  ${green}1.$plain 电信
  ${green}2.$plain 联通"
                read -p "(默认: 取消):" jxtvnet_lane
                case $jxtvnet_lane in
                    1) 
                        printf '%s\n' "59.63.205.33 access.jxtvnet.tv" >> "/etc/hosts"
                        printf '%s\n' "59.63.205.33 stream.slave.jxtvnet.tv" >> "/etc/hosts"
                        printf '%s\n' "59.63.205.33 slave.jxtvnet.tv" >> "/etc/hosts"
                    ;;
                    2) 
                        printf '%s\n' "110.52.240.146 access.jxtvnet.tv" >> "/etc/hosts"
                        printf '%s\n' "110.52.240.146 stream.slave.jxtvnet.tv" >> "/etc/hosts"
                        printf '%s\n' "110.52.240.146 slave.jxtvnet.tv" >> "/etc/hosts"
                    ;;
                    *) echo "已取消..." && exit 1
                    ;;
                esac
            fi

            echo && echo -e "$info 选择操作
  ${green}1.$plain 登录以获取ts链接
  ${green}2.$plain 注册账号"
            read -p "(默认: 取消):" channel_act
            [ -z "$channel_act" ] && echo "已取消..." && exit 1
            
            case $channel_act in
                1) TsLogin
                ;;
                2) TsRegister
                ;;
                *) echo "已取消..." && exit 1
                ;;
            esac
            
            break
        else
            echo -e "$error序号错位，请重新输入！"
        fi
    done
    
}

MonitorError()
{
    printf '%s\n' "$(date -d now "+%m-%d %H:%M:%S") [LINE:$1] ERROR: $?" >> "$MONITOR_LOG"
}

MonitorRestartChannel()
{
    trap '' HUP INT TERM
    trap 'MonitorError $LINENO' ERR
    restart_nums=${restart_nums:-20}
    for((i=0;i<restart_nums;i++))
    do
        chnl_pid=$($JQ_FILE '.channels[] | select(.output_dir_name=="'"$output_dir_name"'").pid' $CHANNELS_FILE)
        GetChannelInfo
        if [ "$chnl_status" == "on" ]
        then
            action="skip"
            StopChannel || true
            if [ "${stopped:-}" == 1 ] 
            then
                sleep 3
                StartChannel || true
                sleep 15
                chnl_pid=$($JQ_FILE '.channels[] | select(.output_dir_name=="'"$output_dir_name"'").pid' $CHANNELS_FILE)
                if ls -A "$LIVE_ROOT/$output_dir_name/"* > /dev/null 2>&1 
                then
                    FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
                    FFPROBE="$FFMPEG_ROOT/ffprobe"
                    bit_rate=$($FFPROBE -v quiet -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$LIVE_ROOT/$output_dir_name/$chnl_seg_dir_name/"*_00000.ts || true)
                    bit_rate=${bit_rate//N\/A/0}
                    audio_stream=$($FFPROBE -i "$LIVE_ROOT/$output_dir_name/$chnl_seg_dir_name/"*_00000.ts -show_streams -select_streams a -loglevel quiet || true)
                    if [ "${bit_rate:-0}" -gt 500000 ] && [ -n "$audio_stream" ]
                    then
                        date_now=$(date -d now "+%m-%d %H:%M:%S")
                        printf '%s\n' "$date_now $chnl_channel_name 重启成功" >> "$MONITOR_LOG"
                        break
                    fi
                elif [[ $i -eq $((restart_nums - 1)) ]] 
                then
                    StopChannel || true
                    date_now=$(date -d now "+%m-%d %H:%M:%S")
                    printf '%s\n' "$date_now $chnl_channel_name 重启失败" >> "$MONITOR_LOG"
                    break
                fi
            fi
        else
            StartChannel || true
            sleep 15
            chnl_pid=$($JQ_FILE '.channels[] | select(.output_dir_name=="'"$output_dir_name"'").pid' $CHANNELS_FILE)
            if ls -A "$LIVE_ROOT/$output_dir_name/"* > /dev/null 2>&1 
            then
                FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
                FFPROBE="$FFMPEG_ROOT/ffprobe"
                bit_rate=$($FFPROBE -v quiet -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$LIVE_ROOT/$output_dir_name/$chnl_seg_dir_name/"*_00000.ts || true)
                bit_rate=${bit_rate//N\/A/0}
                audio_stream=$($FFPROBE -i "$LIVE_ROOT/$output_dir_name/$chnl_seg_dir_name/"*_00000.ts -show_streams -select_streams a -loglevel quiet || true)
                if [ "${bit_rate:-0}" -gt 500000 ] && [ -n "$audio_stream" ]
                then
                    date_now=$(date -d now "+%m-%d %H:%M:%S")
                    printf '%s\n' "$date_now $chnl_channel_name 重启成功" >> "$MONITOR_LOG"
                    break
                fi
            elif [[ $i -eq $((restart_nums - 1)) ]] 
            then
                StopChannel || true
                date_now=$(date -d now "+%m-%d %H:%M:%S")
                printf '%s\n' "$date_now $chnl_channel_name 重启失败" >> "$MONITOR_LOG"
                break
            fi
        fi
    done
}

Monitor()
{
    trap '' HUP INT TERM QUIT EXIT
    trap 'MonitorError $LINENO' ERR
    printf '%s' "$BASHPID" > "$MONITOR_PID"
    date_now=$(date -d now "+%m-%d %H:%M:%S")
    monitor=1
    mkdir -p "$LIVE_ROOT"
    printf '%s\n' "$date_now 监控启动成功 PID $BASHPID !" >> "$MONITOR_LOG"
    echo -e "$info 监控启动成功 !"
    while true; do
        if [ -n "${flv_nums:-}" ] 
        then
            kind="flv"
            if [ -n "${flv_all:-}" ] 
            then
                for((i=0;i<flv_count;i++));
                do
                    chnl_flv_pull_link=${chnls_flv_pull_link[$i]}
                    chnl_flv_pull_link=${chnl_flv_pull_link//\'/}
                    chnl_flv_push_link=${chnls_flv_push_link[$i]}
                    chnl_flv_push_link=${chnl_flv_push_link//\'/}
                    FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
                    FFPROBE="$FFMPEG_ROOT/ffprobe"
                    audio_stream=$($FFPROBE -i "${chnl_flv_pull_link:-$chnl_flv_push_link}" -show_streams -select_streams a -loglevel quiet || true)
                    if [ -z "${audio_stream:-}" ] 
                    then
                        chnl_pid=$($JQ_FILE '.channels[] | select(.flv_push_link=="'"$chnl_flv_push_link"'").pid' $CHANNELS_FILE)
                        GetChannelInfo

                        if [ "${flv_restart_count:-1}" -gt "${flv_restart_nums:-20}" ] 
                        then
                            if [ "$chnl_flv_status" == "on" ] 
                            then
                                StopChannel || true
                                printf '%s\n' "$(date -d now "+%m-%d %H:%M:%S") $chnl_channel_name flv 重启超过${flv_restart_nums:-20}次关闭" >> "$MONITOR_LOG"
                            fi

                            unset 'chnls_flv_push_link[0]'
                            declare -a new_array
                            for element in "${chnls_flv_push_link[@]}"
                            do
                                new_array[$i]=$element
                                ((++i))
                            done
                            chnls_flv_push_link=("${new_array[@]}")
                            unset new_array

                            unset 'chnls_flv_pull_link[0]'
                            declare -a new_array
                            i=0
                            for element in "${chnls_flv_pull_link[@]}"
                            do
                                new_array[$i]=$element
                                ((++i))
                            done
                            chnls_flv_pull_link=("${new_array[@]}")
                            unset new_array

                            flv_first_fail=""
                            flv_restart_count=1
                            ((flv_count--))
                            break 1
                        fi

                        if [ -n "${flv_first_fail:-}" ]
                        then
                            flv_fail_date=$(date +%s)
                            if [ $((flv_fail_date - flv_first_fail)) -gt "$flv_seconds" ] 
                            then
                                action="skip"
                                StopChannel || true
                                if [ "${stopped:-}" == 1 ] 
                                then
                                    sleep 3
                                    StartChannel || true
                                    flv_restart_count=${flv_restart_count:-1}
                                    ((flv_restart_count++))
                                    flv_first_fail=""
                                    printf '%s\n' "$(date -d now "+%m-%d %H:%M:%S") $chnl_channel_name flv 超时重启" >> "$MONITOR_LOG"
                                    sleep 10
                                fi
                            fi
                        else
                            if [ "$chnl_flv_status" == "off" ] 
                            then
                                StartChannel || true
                                flv_restart_count=${flv_restart_count:-1}
                                ((flv_restart_count++))
                                flv_first_fail=""
                                printf '%s\n' "$(date -d now "+%m-%d %H:%M:%S") $chnl_channel_name flv 恢复启动" >> "$MONITOR_LOG"
                                sleep 10
                            else
                                flv_first_fail=$(date +%s)
                            fi

                            new_array=("$chnl_flv_push_link")
                            for element in "${chnls_flv_push_link[@]}"
                            do
                                [ "${element//\'/}" != "$chnl_flv_push_link" ] && new_array+=("$element")
                            done
                            chnls_flv_push_link=("${new_array[@]}")
                            unset new_array

                            new_array=("${chnls_flv_pull_link[$i]}")
                            for((j=0;j<flv_count;j++));
                            do
                                [ "$j" != "$i" ] && new_array+=("${chnls_flv_pull_link[$j]}")
                            done
                            chnls_flv_pull_link=("${new_array[@]}")
                            unset new_array
                        fi

                        break 1
                    else
                        flv_first_fail=""
                        flv_restart_count=1
                    fi
                done
            else
                for flv_num in "${flv_nums_arr[@]}"
                do
                    chnl_flv_pull_link=${chnls_flv_pull_link[$((flv_num-1))]}
                    chnl_flv_pull_link=${chnl_flv_pull_link//\'/}
                    chnl_flv_push_link=${chnls_flv_push_link[$((flv_num-1))]}
                    chnl_flv_push_link=${chnl_flv_push_link//\'/}
                    FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
                    FFPROBE="$FFMPEG_ROOT/ffprobe"
                    audio_stream=$($FFPROBE -i "${chnl_flv_pull_link:-$chnl_flv_push_link}" -show_streams -select_streams a -loglevel quiet || true)
                    if [ -z "${audio_stream:-}" ] 
                    then
                        chnl_pid=$($JQ_FILE '.channels[] | select(.flv_push_link=="'"$chnl_flv_push_link"'").pid' $CHANNELS_FILE)
                        GetChannelInfo

                        if [ "${flv_restart_count:-1}" -gt "${flv_restart_nums:-20}" ] 
                        then
                            if [ "$chnl_flv_status" == "on" ] 
                            then
                                StopChannel || true
                                printf '%s\n' "$(date -d now "+%m-%d %H:%M:%S") $chnl_channel_name flv 重启超过${flv_restart_nums:-20}次关闭" >> "$MONITOR_LOG"
                            fi

                            declare -a new_array
                            for element in "${flv_nums_arr[@]}"
                            do
                                [ "$element" != "$flv_num" ] && new_array+=("$element")
                            done
                            flv_nums_arr=("${new_array[@]}")
                            unset new_array

                            flv_first_fail=""
                            flv_restart_count=1
                            break 1
                        fi

                        if [ -n "${flv_first_fail:-}" ] 
                        then
                            flv_fail_date=$(date +%s)
                            if [ $((flv_fail_date - flv_first_fail)) -gt "$flv_seconds" ] 
                            then
                                action="skip"
                                StopChannel || true
                                if [ "${stopped:-}" == 1 ] 
                                then
                                    sleep 3
                                    StartChannel || true
                                    flv_restart_count=${flv_restart_count:-1}
                                    ((flv_restart_count++))
                                    flv_first_fail=""
                                    printf '%s\n' "$(date -d now "+%m-%d %H:%M:%S") $chnl_channel_name flv 超时重启" >> "$MONITOR_LOG"
                                    sleep 10
                                fi
                            fi
                        else
                            if [ "$chnl_flv_status" == "off" ] 
                            then
                                StartChannel || true
                                flv_restart_count=${flv_restart_count:-1}
                                ((flv_restart_count++))
                                flv_first_fail=""
                                printf '%s\n' "$(date -d now "+%m-%d %H:%M:%S") $chnl_channel_name flv 恢复启动" >> "$MONITOR_LOG"
                                sleep 10
                            else
                                flv_first_fail=$(date +%s)
                            fi

                            new_array=("$flv_num")
                            for element in "${flv_nums_arr[@]}"
                            do
                                [ "$element" != "$flv_num" ] && new_array+=("$element")
                            done
                            flv_nums_arr=("${new_array[@]}")
                            unset new_array
                        fi

                        break 1
                    else
                        flv_first_fail=""
                        flv_restart_count=1
                    fi
                done
            fi
        fi

        kind=""

        if [ -n "${delay_seconds:-}" ] && ls -A $LIVE_ROOT/* > /dev/null 2>&1
        then
            while IFS= read -r old_file_path
            do
                if [[ "$old_file_path" == *"_master.m3u8" ]] 
                then
                    continue
                fi
                output_dir_name=${old_file_path#*$LIVE_ROOT/}
                output_dir_name=${output_dir_name%%/*}
                if [ "${monitor_all}" == 1 ] 
                then
                    channel_name=$($JQ_FILE -r '.channels[]|select(.output_dir_name=="'"$output_dir_name"'").channel_name' "$CHANNELS_FILE")
                    printf '%s\n' "$channel_name 超时重启" >> "$MONITOR_LOG"
                    MonitorRestartChannel
                    break 1
                else
                    for dir_name in "${monitor_dir_names_chosen[@]}"
                    do
                        if [ "$dir_name" == "$output_dir_name" ] 
                        then
                            channel_name=$($JQ_FILE -r '.channels[]|select(.output_dir_name=="'"$dir_name"'").channel_name' "$CHANNELS_FILE")
                            printf '%s\n' "$channel_name 超时重启" >> "$MONITOR_LOG"
                            MonitorRestartChannel
                            break 2
                        fi
                    done  
                fi
            done < <(find "$LIVE_ROOT/"* \! -newermt "-$delay_seconds seconds" || true)
            
            for dir_name in "${monitor_dir_names_chosen[@]}"
            do
                chnl_pid=$($JQ_FILE '.channels[] | select(.output_dir_name=="'"$dir_name"'").pid' $CHANNELS_FILE)
                GetChannelInfo
                FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
                FFPROBE="$FFMPEG_ROOT/ffprobe"
                bit_rate=$($FFPROBE -v quiet -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$LIVE_ROOT/$dir_name/$chnl_seg_dir_name/"*_00000.ts || true)
                bit_rate=${bit_rate:-500000}
                bit_rate=${bit_rate//N\/A/500000}
                #audio_stream=$($FFPROBE -i "$LIVE_ROOT/$dir_name/$chnl_seg_dir_name/"*_00000.ts -show_streams -select_streams a -loglevel quiet || true)
                if [[ $bit_rate -lt 500000 ]] # || [ -z "$audio_stream" ]
                then
                    output_dir_name=$dir_name
                    fail_count=1
                    for f in "$LIVE_ROOT/$dir_name/$chnl_seg_dir_name/"*.ts
                    do
                        bit_rate=$($FFPROBE -v quiet -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$f" || true)
                        bit_rate=${bit_rate:-500000}
                        bit_rate=${bit_rate//N\/A/500000}
                        if [[ $bit_rate -lt 500000 ]] 
                        then
                            ((fail_count++))
                        fi
                        if [ "$fail_count" -gt 2 ] 
                        then
                            channel_name=$($JQ_FILE -r '.channels[]|select(.output_dir_name=="'"$output_dir_name"'").channel_name' "$CHANNELS_FILE")
                            printf '%s\n' "$channel_name 比特率过低重启" >> "$MONITOR_LOG"
                            MonitorRestartChannel
                            break 1
                        fi
                    done
                fi
            done
        fi

        if ls -A $LIVE_ROOT/* > /dev/null 2>&1 
        then
            largest_file=$(find "$LIVE_ROOT" -type f -printf "%s %p\n" | sort -n | tail -1 || true)
            if [ -n "${largest_file:-}" ] 
            then
                largest_file_size=${largest_file%% *}
                largest_file_path=${largest_file#* }
                output_dir_name=${largest_file_path#*$LIVE_ROOT/}
                output_dir_name=${output_dir_name%%/*}
                if [ "$largest_file_size" -gt $(( cmd * 1000000)) ]
                then
                    channel_name=$($JQ_FILE -r '.channels[]|select(.output_dir_name=="'"$output_dir_name"'").channel_name' "$CHANNELS_FILE")
                    printf '%s\n' "$channel_name 文件过大重启" >> "$MONITOR_LOG"
                    MonitorRestartChannel
                fi
            fi
        fi
        sleep 5
    done
}

MonitorSet()
{

    IFS=" " read -ra chnls_flv_push_link <<< "$($JQ_FILE -r '[.channels[]|select(.flv_status=="on").flv_push_link] | @sh' $CHANNELS_FILE)"

    if [ -n "${chnls_flv_push_link:-}" ] 
    then
        chnls_channel_name=()
        while IFS='' read -r name
        do
            chnls_channel_name+=("$name");
        done < <($JQ_FILE -r '.channels[]|select(.flv_status=="on").channel_name | @sh' "$CHANNELS_FILE")
        IFS=" " read -ra chnls_flv_pull_link <<< "$($JQ_FILE -r '[.channels[]|select(.flv_status=="on").flv_pull_link] | @sh' $CHANNELS_FILE)"
        flv_count=${#chnls_channel_name[@]}

        echo && echo "请选择需要监控的 FLV 推流频道(多个频道用空格分隔)" && echo

        for((i=0;i<flv_count;i++));
        do
            echo -e "  ${green}$((i+1)).$plain ${chnls_channel_name[$i]//\'/} ${chnls_flv_pull_link[$i]//\'/}"
        done

        echo && echo -e "  ${green}$((i+1)).$plain 全部"
        echo -e "  ${green}$((i+2)).$plain 不设置" && echo
        while read -p "(默认: 不设置):" flv_nums
        do
            if [ -z "$flv_nums" ] || [ "$flv_nums" == $((i+2)) ] 
            then
                flv_nums=""
                break
            fi
            IFS=" " read -ra flv_nums_arr <<< "$flv_nums"

            if [ "$flv_nums" == $((i+1)) ] 
            then
                flv_all=1
                echo && echo "设置超时多少秒自动重启频道"
                while read -p "(默认: 20秒):" flv_seconds
                do
                    case $flv_seconds in
                        "") flv_seconds=20 && break
                        ;;
                        *[!0-9]*) echo && echo -e "$error 请输入正确的数字" && echo
                        ;;
                        *) 
                            if [ "$flv_seconds" -gt 20 ]
                            then
                                break
                            else
                                echo && echo -e "$error 请输入正确的数字(大于20)" && echo
                            fi
                        ;;
                    esac
                done
                break
            fi

            error=0
            for flv_num in "${flv_nums_arr[@]}"
            do
                case "$flv_num" in
                    *[!0-9]*)
                        error=1
                    ;;
                    *)
                        if [ "$flv_num" -lt 1 ] || [ "$flv_num" -gt "$flv_count" ]
                        then
                            error=2
                        fi
                    ;;
                esac
            done

            case "$error" in
                1|2)
                    echo -e "$error 请输入正确的数字或直接回车 " && echo
                ;;
                *)
                    echo && echo "设置超时多少秒自动重启频道"
                    while read -p "(默认: 20秒):" flv_seconds
                    do
                        case $flv_seconds in
                            "") flv_seconds=20 && break
                            ;;
                            *[!0-9]*) echo && echo -e "$error 请输入正确的数字" && echo
                            ;;
                            *) 
                                if [ "$flv_seconds" -gt 20 ]
                                then
                                    break
                                else
                                    echo && echo -e "$error 请输入正确的数字(大于20)" && echo
                                fi
                            ;;
                        esac
                    done
                    break
                ;;
            esac
        done

        echo && echo "请输入尝试重启的次数"
        while read -p "(默认: 20次):" flv_restart_nums
        do
            case $flv_restart_nums in
                "") flv_restart_nums=20 && break
                ;;
                *[!0-9]*) echo && echo -e "$error 请输入正确的数字" && echo
                ;;
                *) 
                    if [ "$flv_restart_nums" -gt 0 ]
                    then
                        break
                    else
                        echo && echo -e "$error 请输入正确的数字(大于0)" && echo
                    fi
                ;;
            esac
        done
    fi

    if ! ls -A $LIVE_ROOT/* > /dev/null 2>&1
    then
        return 0
    fi
    echo && echo "请选择需要监控超时重启的 HLS 频道(多个频道用空格分隔)"
    echo "一般不需要设置，只有在需要重启频道才能继续连接直播源的情况下启用" && echo
    monitor_count=0
    monitor_dir_names=()
    for dir in "$LIVE_ROOT"/*/
    do
        monitor_count=$((monitor_count + 1))
        file_root=${dir%/*}
        output_dir_name=${file_root##*/}
        channel_name=$($JQ_FILE -r '.channels[]|select(.output_dir_name=="'"$output_dir_name"'").channel_name' "$CHANNELS_FILE")
        monitor_dir_names+=("$output_dir_name")
        echo -e "  ${green}$monitor_count.$plain $channel_name"
    done
    echo && echo -e "  ${green}$((monitor_count+1)).$plain 全部"
    echo -e "  ${green}$((monitor_count+2)).$plain 不设置" && echo
    
    while read -p "(默认: 不设置):" monitor_nums
    do
        if [ -z "$monitor_nums" ] || [ "$monitor_nums" == $((monitor_count+2)) ] 
        then
            monitor_nums=""
            break
        fi
        IFS=" " read -ra monitor_nums_arr <<< "$monitor_nums"

        monitor_dir_names_chosen=()
        if [ "$monitor_nums" == $((monitor_count+1)) ] 
        then
            monitor_all=1
            monitor_dir_names_chosen=("${monitor_dir_names[@]}")

            echo && echo "设置超时多少秒自动重启频道"
            echo "必须大于 段时长*段数目"
            while read -p "(默认: 120秒):" delay_seconds
            do
                case $delay_seconds in
                    "") delay_seconds=120 && break
                    ;;
                    *[!0-9]*) echo && echo -e "$error 请输入正确的数字" && echo
                    ;;
                    *) 
                        if [ "$delay_seconds" -gt 60 ]
                        then
                            break
                        else
                            echo && echo -e "$error 请输入正确的数字(大于60)" && echo
                        fi
                    ;;
                esac
            done
            break
        else
            monitor_all=0
        fi

        error=0
        for monitor_key in "${monitor_nums_arr[@]}"
        do
            case "$monitor_key" in
                *[!0-9]*)
                    error=1
                ;;
                *)
                    if [ "$monitor_key" -lt 1 ] || [ "$monitor_key" -gt "$monitor_count" ]
                    then
                        error=2
                    fi
                ;;
            esac
        done

        case "$error" in
            1|2)
                echo -e "$error 请输入正确的数字或直接回车 " && echo
            ;;
            *)
                for monitor_key in "${monitor_nums_arr[@]}"
                do
                    monitor_dir_names_chosen+=("${monitor_dir_names[((monitor_key - 1))]}")
                done

                echo && echo "设置超时多少秒自动重启频道"
                while read -p "(默认: 120秒):" delay_seconds
                do
                    case $delay_seconds in
                        "") delay_seconds=120 && break
                        ;;
                        *[!0-9]*) echo && echo -e "$error 请输入正确的数字" && echo
                        ;;
                        *) break
                        ;;
                    esac
                done

                break
            ;;
        esac
    done

    echo && echo "请输入尝试重启的次数"
    while read -p "(默认: 20次):" restart_nums
    do
        case $restart_nums in
            "") restart_nums=20 && break
            ;;
            *[!0-9]*) echo && echo -e "$error 请输入正确的数字" && echo
            ;;
            *) 
                if [ "$restart_nums" -gt 0 ]
                then
                    break
                else
                    echo && echo -e "$error 请输入正确的数字(大于0)" && echo
                fi
            ;;
        esac
    done
}

MonitorStop()
{
    date_now=$(date -d now "+%m-%d %H:%M:%S")
    if [ ! -s "$MONITOR_PID" ] 
    then
        echo -e "$error 监控未启动 !"
    else
        PID=$(< "$MONITOR_PID")
        if kill -0 "$PID" 2> /dev/null
        then
            if kill -9 "$PID" 2> /dev/null 
            then
                printf '%s\n' "$date_now 监控关闭成功 PID $PID !" >> "$MONITOR_LOG"
                echo -e "$info 监控关闭成功 !"
            else
                printf '%s\n' "$date_now 监控关闭失败 PID $PID !" >> "$MONITOR_LOG"
                echo -e "$error 监控关闭失败 !"
            fi
        else
            echo -e "$error 监控未启动 !"
        fi
    fi
}

Usage()
{

cat << EOM
HTTP Live Stream Creator
Wrapper By MTimer

Copyright (C) 2013 B Tasker, D Atanasov
Released under BSD 3 Clause License
See LICENSE

使用方法: tv -i [直播源] [-s 段时长(秒)] [-o 输出目录名称] [-c m3u8包含的段数目] [-b 比特率] [-p m3u8文件名称] [-C]

    -i  直播源(支持 mpegts / hls / flv ...)
        hls 链接需包含 .m3u8 标识
    -s  段时长(秒)(默认：6)
    -o  输出目录名称(默认：随机名称)

    -p  m3u8名称(前缀)(默认：随机)
    -c  m3u8里包含的段数目(默认：5)
    -S  段所在子目录名称(默认：不使用子目录)
    -t  段名称(前缀)(默认：跟m3u8名称相同)
    -a  音频编码(默认：aac) (不需要转码时输入 copy)
    -v  视频编码(默认：h264) (不需要转码时输入 copy)
    -f  画面或声音延迟(格式如： v_3 画面延迟3秒，a_2 声音延迟2秒
        如果转码时使用此功能*暂时*会忽略部分参数，建议 copy 直播源(画面声音不同步)时使用)
    -q  crf视频质量(如果同时设置了输出视频比特率，则优先使用crf视频质量)(数值1~63 越大质量越差)
        (默认: 不设置crf视频质量值)
    -b  输出视频的比特率(bits/s)(默认：900-1280x720)
        如果已经设置crf视频质量值，则比特率用于 -maxrate -bufsize
        如果没有设置crf视频质量值，则可以继续设置是否固定码率
        多个比特率用逗号分隔(注意-如果设置多个比特率，就是生成自适应码流)
        同时可以指定输出的分辨率(比如：-b 600-600x400,900-1280x720)
        可以输入 copy 省略此选项(不需要转码时)
    -C  固定码率(CBR 而不是 AVB)(只有在没有设置crf视频质量的情况下才有效)(默认：否)
    -e  加密段(默认：不加密)
    -K  Key名称(默认：跟m3u8名称相同)
    -z  频道名称(默认：跟m3u8名称相同)

    也可以不输出 HLS，比如 flv 推流
    -k  设置推流类型，比如 -k flv
    -T  设置推流地址，比如 rtmp://127.0.0.1/live/xxx
    -L  输入拉流(播放)地址(可省略)，比如 http://domain.com/live?app=live&stream=xxx

    -m  ffmpeg 额外的 INPUT FLAGS
        (默认："-reconnect 1 -reconnect_at_eof 1 
        -reconnect_streamed 1 -reconnect_delay_max 2000 
        -timeout 2000000000 -y -thread_queue_size 55120 
        -nostats -nostdin -hide_banner -loglevel 
        fatal -probesize 65536")
    -n  ffmpeg 额外的 OUTPUT FLAGS, 可以输入 copy 省略此选项(不需要转码时)
        (默认："-g 25 -sc_threshold 0 -sn -preset superfast -pix_fmt yuv420p -profile:v main")

举例:
    使用crf值控制视频质量: 
        tv -i http://xxx.com/xxx.ts -s 6 -o hbo1 -p hbo1 -q 15 -b 1500-1280x720 -z 'hbo直播1'
    使用比特率控制视频质量[默认]: 
        tv -i http://xxx.com/xxx.ts -s 6 -o hbo2 -p hbo2 -b 900-1280x720 -z 'hbo直播2'

    不需要转码的设置: -a copy -v copy -n copy

    不输出 HLS, 推流 flv :
        tv -i http://xxx/xxx.ts -a copy -v h264 -b 3000 -k flv -T rtmp://127.0.0.1/live/xxx

EOM

exit

}

if [ -e "$IPTV_ROOT" ] && [ ! -e "$LOCK_FILE" ] 
then
    UpdateSelf
fi

if [[ -n ${1+x} ]]
then
    case $1 in
        "s") 
            [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请先安装 !" && exit 1
            Schedule "$@"
            exit 0
        ;;
        "m") 
            [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请先安装 !" && exit 1

            cmd=${2:-5}

            case $cmd in
                "stop") 
                    MonitorStop
                ;;
                "log")
                    tail -f "$MONITOR_LOG"
                ;;
                *[!0-9]*)
                    echo -e "$error 请输入正确的数字(大于0) "
                ;;
                0)
                    echo -e "$error 请输入正确的数字(大于0) "
                ;;
                *) 
                    if [ ! -s "$MONITOR_PID" ] 
                    then
                        MonitorSet
                        Monitor &
                    else
                        PID=$(< "$MONITOR_PID")
                        if kill -0 "$PID" 2> /dev/null 
                        then
                            echo -e "$error 监控已经在运行 !"
                        else
                            MonitorSet
                            Monitor &
                        fi
                    fi
                ;;
            esac

            exit 0
        ;;
        "t") 
            [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1

            if [ -z ${2+x} ] 
            then
                echo -e "$error 请指定文件 !" && exit 1
            elif [ ! -e "$2" ] 
            then
                echo -e "$error 文件不存在 !" && exit 1
            fi

            echo && echo "请输入测试的频道ID"
            while read -p "(默认: 取消):" channel_id
            do
                case $channel_id in
                    "") echo && echo -e "$error 已取消..." && exit 1
                    ;;
                    *[!0-9]*) echo && echo -e "$error 请输入正确的数字" && echo
                    ;;
                    *) 
                        if [ "$channel_id" -gt 0 ]
                        then
                            break
                        else
                            echo && echo -e "$error 请输入正确的ID(大于0)" && echo
                        fi
                    ;;
                esac
            done
            

            set +euo pipefail
            
            while IFS= read -r line
            do
                if [[ $line == *"username="* ]] 
                then
                    domain_line=${line#*http://}
                    domain=${domain_line%%/*}
                    u_line=${line#*username=}
                    p_line=${line#*password=}
                    username=${u_line%%&*}
                    password=${p_line%%&*}
                    link="http://$domain/$username/$password/$channel_id"
                    if curl --output /dev/null --silent --fail -r 0-0 "$link"
                    then
                        echo "$link"
                    fi
                fi
            done < "$2"

            exit 0
        ;;
        *)
        ;;
    esac
fi

use_menu=1

while getopts "i:o:p:S:t:s:c:v:a:f:q:b:k:K:m:n:z:T:L:Ce" flag
do
    use_menu=0
        case "$flag" in
            i) stream_link="$OPTARG";;
            o) output_dir_name="$OPTARG";;
            p) playlist_name="$OPTARG";;
            S) seg_dir_name="$OPTARG";;
            t) seg_name="$OPTARG";;
            s) seg_length="$OPTARG";;
            c) seg_count="$OPTARG";;
            v) video_codec="$OPTARG";;
            a) audio_codec="$OPTARG";;
            f) video_audio_shift="$OPTARG";;
            q) quality="$OPTARG";;
            b) bitrates="$OPTARG";;
            C) const="-C";;
            e) encrypt="-e";;
            k) kind="$OPTARG";;
            K) key_name="$OPTARG";;
            m) input_flags="$OPTARG";;
            n) output_flags="$OPTARG";;
            z) channel_name="$OPTARG";;
            T) flv_push_link="$OPTARG";;
            L) flv_pull_link="$OPTARG";;
            *) Usage;
        esac
done

cmd=$*
case "$cmd" in
    "e") 
        [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
        vi "$CHANNELS_FILE" && exit 0
    ;;
    "ee") 
        [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
        GetDefault
        [ -z "$d_sync_file" ] && echo -e "$error sync_file 未设置，请检查 !" && exit 1
        vi "$d_sync_file" && exit 0
    ;;
    "d")
        [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
        wget "$DEFAULT_DEMOS" -qO "$CHANNELS_TMP"
        channels=$(< "$CHANNELS_TMP")
        $JQ_FILE '.channels += '"$channels"'' "$CHANNELS_FILE" > "$CHANNELS_TMP"
        mv "$CHANNELS_TMP" "$CHANNELS_FILE"
        echo && echo -e "$info 频道添加成功 !" && echo
        exit 0
    ;;
    "ffmpeg") 
        [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
        mkdir -p "$FFMPEG_MIRROR_ROOT/builds"
        mkdir -p "$FFMPEG_MIRROR_ROOT/releases"
        git_download=0
        release_download=0
        git_version_old=""
        release_version_old=""
        if [ -e "$FFMPEG_MIRROR_ROOT/index.html" ] 
        then
            while IFS= read -r line
            do
                if [[ $line == *"<th>"* ]] 
                then
                    if [[ $line == *"git"* ]] 
                    then
                        git_version_old=$line
                    else
                        release_version_old=$line
                    fi
                fi
            done < "$FFMPEG_MIRROR_ROOT/index.html"
        fi

        wget --no-check-certificate "https://www.johnvansickle.com/ffmpeg/index.html" -qO "$FFMPEG_MIRROR_ROOT/index.html"
        wget --no-check-certificate "https://www.johnvansickle.com/ffmpeg/style.css" -qO "$FFMPEG_MIRROR_ROOT/style.css"

        while IFS= read -r line
        do
            if [[ $line == *"<th>"* ]] 
            then
                if [[ $line == *"git"* ]] 
                then
                    git_version_new=$line
                    [ "$git_version_new" != "$git_version_old" ] && git_download=1
                else
                    release_version_new=$line
                    [ "$release_version_new" != "$release_version_old" ] && release_download=1
                fi
            fi

            if [[ $line == *"tar.xz"* ]]  
            then
                if [[ $line == *"git"* ]] && [ "$git_download" == 1 ]
                then
                    line=${line#*<td><a href=\"}
                    git_link=${line%%\" style*}
                    build_file_name=${git_link##*/}
                    wget --no-check-certificate "$git_link" --show-progress -qO "$FFMPEG_MIRROR_ROOT/builds/${build_file_name}_tmp"
                    mv "$FFMPEG_MIRROR_ROOT/builds/${build_file_name}_tmp" "$FFMPEG_MIRROR_ROOT/builds/${build_file_name}"
                else 
                    if [ "$release_download" == 1 ] 
                    then
                        line=${line#*<td><a href=\"}
                        release_link=${line%%\" style*}
                        release_file_name=${release_link##*/}
                        wget --no-check-certificate "$release_link" --show-progress -qO "$FFMPEG_MIRROR_ROOT/releases/${release_file_name}_tmp"
                        mv "$FFMPEG_MIRROR_ROOT/releases/${release_file_name}_tmp" "$FFMPEG_MIRROR_ROOT/releases/${release_file_name}"
                    fi
                fi
            fi

        done < "$FFMPEG_MIRROR_ROOT/index.html"

        #echo && echo "输入镜像网站链接(比如：$FFMPEG_MIRROR_LINK)"
        #read -p "(默认: 取消): " FFMPEG_LINK
        #[ -z "$FFMPEG_LINK" ] && echo "已取消..." && exit 1
        #sed -i "s+https://johnvansickle.com/ffmpeg/\(builds\|releases\)/\(.*\).tar.xz\"+$FFMPEG_LINK/\1/\2.tar.xz\"+g" "$FFMPEG_MIRROR_ROOT/index.html"

        sed -i "s+https://johnvansickle.com/ffmpeg/\(builds\|releases\)/\(.*\).tar.xz\"+\1/\2.tar.xz\"+g" "$FFMPEG_MIRROR_ROOT/index.html"
        exit 0
    ;;
    "ts") 
        [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
        TsMenu
        exit 0
    ;;
    "f") 
        [ ! -e "$IPTV_ROOT" ] && echo -e "$error 尚未安装，请检查 !" && exit 1
        kind="flv"
    ;;
    "ll") 
        for d in "$LIVE_ROOT"/*/ ; do
            ls "$d" -lght
        done
        exit 0
    ;;
    *)
    ;;
esac

if [ "$use_menu" == "1" ]
then
    [ ! -e "$SH_FILE" ] && wget --no-check-certificate "$SH_LINK" -qO "$SH_FILE" && chmod +x "$SH_FILE"
    if [ ! -s "$SH_FILE" ] 
    then
        echo -e "$error 无法连接到 Github ! 尝试备用链接..."
        wget --no-check-certificate "$SH_LINK_BACKUP" -qO "$SH_FILE" && chmod +x "$SH_FILE"
        if [ ! -s "$SH_FILE" ] 
        then
            echo -e "$error 无法连接备用链接!"
            exit 1
        fi
    fi
    echo -e "  IPTV 一键管理脚本（mpegts / hls / flv => hls / flv 推流）${red}[v$sh_ver]$plain
  ---- MTimer | http://hbo.epub.fun ----

  ${green}1.$plain 安装
  ${green}2.$plain 卸载
  ${green}3.$plain 升级脚本
————————————
  ${green}4.$plain 查看频道
  ${green}5.$plain 添加频道
  ${green}6.$plain 修改频道
  ${green}7.$plain 开关频道
  ${green}8.$plain 重启频道
  ${green}9.$plain 删除频道

 $tip 输入: tv 打开 HLS 面板, tv f 打开 FLV 面板" && echo
    echo && read -p "请输入数字 [1-9]：" menu_num
    case "$menu_num" in
        1) Install
        ;;
        2) Uninstall
        ;;
        3) Update
        ;;
        4) ViewChannelMenu
        ;;
        5) AddChannel
        ;;
        6) EditChannelMenu
        ;;
        7) ToggleChannel
        ;;
        8) RestartChannel
        ;;
        9) DelChannel
        ;;
        *)
        echo -e "$error 请输入正确的数字 [1-9]"
        ;;
    esac
else
    stream_link=${stream_link:-""}
    if [ -z "$stream_link" ]
    then
        Usage
    else
        CheckRelease
        FFMPEG_ROOT=$(dirname "$IPTV_ROOT"/ffmpeg-git-*/ffmpeg)
        FFMPEG="$FFMPEG_ROOT/ffmpeg"
        if [ ! -e "$FFMPEG" ]
        then
            echo && read -p "尚未安装,是否现在安装？[y/N] (默认: N): " install_yn
            install_yn=${install_yn:-"N"}
            if [[ "$install_yn" == [Yy] ]]
            then
                Install
            else
                echo "已取消..." && exit 1
            fi
        else
            GetDefault
            export FFMPEG
            output_dir_name=${output_dir_name:-"$(RandOutputDirName)"}
            output_dir_root="$LIVE_ROOT/$output_dir_name"
            playlist_name=${playlist_name:-"$(RandPlaylistName)"}
            export SEGMENT_DIRECTORY=${seg_dir_name:-""}
            seg_name=${seg_name:-"$playlist_name"}
            seg_length=${seg_length:-"$d_seg_length"}
            seg_count=${seg_count:-"$d_seg_count"}
            export AUDIO_CODEC=${audio_codec:-"$d_audio_codec"}
            export VIDEO_CODEC=${video_codec:-"$d_video_codec"}
            
            video_audio_shift=${video_audio_shift:-""}
            v_or_a=${video_audio_shift%_*}
            if [ "$v_or_a" == "v" ] 
            then
                video_shift=${video_audio_shift#*_}
            elif [ "$v_or_a" == "a" ] 
            then
                audio_shift=${video_audio_shift#*_}
            fi

            quality=${quality:-"$d_quality"}
            bitrates=${bitrates:-"$d_bitrates"}
            quality_command=""
            bitrates_command=""

            if [ -z "${const:-}" ]  
            then
                if [ "$d_const" == "yes" ] 
                then
                    const="-C"
                    const_yn="yes"
                else
                    const=""
                    const_yn="no"
                fi
            else
                const_yn="yes"
            fi

            if [ -z "${encrypt:-}" ]  
            then
                if [ "$d_encrypt" == "yes" ] 
                then
                    encrypt="-e"
                    encrypt_yn="yes"
                else
                    encrypt=""
                    encrypt_yn="no"
                fi
            else
                encrypt_yn="yes"
            fi

            if [ "${video_codec:-}" == "copy" ] && [ "${audio_codec:-}" == "copy" ]
            then
                quality=""
                bitrates=""
                const=""
                const_yn="no"
            else
                if [ -n "${quality:-}" ] 
                then
                    quality_command="-q $quality"
                fi
                if [ -n "${bitrates:-}" ] 
                then
                    bitrates_command="-b $bitrates"
                fi
            fi

            key_name=${key_name:-"$playlist_name"}

            if [[ ${stream_link:-} == *".m3u8"* ]] 
            then
                d_input_flags=${d_input_flags//-reconnect_at_eof 1/}
            elif [ "${stream_link:0:4}" == "rtmp" ] 
            then
                d_input_flags=${d_input_flags//-timeout 2000000000/}
                d_input_flags=${d_input_flags//-reconnect 1/}
                d_input_flags=${d_input_flags//-reconnect_at_eof 1/}
                d_input_flags=${d_input_flags//-reconnect_streamed 1/}
                d_input_flags=${d_input_flags//-reconnect_delay_max 2000/}
            fi

            input_flags=${input_flags:-"$d_input_flags"}
            export FFMPEG_INPUT_FLAGS=${input_flags//\'/}

            if [ "${output_flags:-}" == "copy" ] 
            then
                output_flags=""
            else
                output_flags=${d_input_flags}
            fi

            export FFMPEG_FLAGS=${output_flags//\'/}
            channel_name=${channel_name:-"$playlist_name"}

            if [ -n "${kind:-}" ] 
            then
                if [ "$kind" == "flv" ] 
                then
                    if [ -z "${flv_push_link:-}" ] 
                    then
                        echo && echo -e "$error 未设置推流地址..." && echo && exit 1
                    else
                        flv_pull_link=${flv_pull_link:-""}
                        from="command"
                        ( FlvStreamCreatorWithShift ) > /dev/null 2>/dev/null </dev/null &
                    fi
                else
                    echo && echo -e "$error 暂不支持输出 $kind ..." && echo && exit 1
                fi
            elif [ -n "${video_audio_shift:-}" ] 
            then
                from="command"
                ( HlsStreamCreatorWithShift ) > /dev/null 2>/dev/null </dev/null &
            else
                exec "$CREATOR_FILE" -l -i "$stream_link" -s "$seg_length" \
                    -o "$output_dir_root" -c "$seg_count" $bitrates_command \
                    -p "$playlist_name" -t "$seg_name" -K "$key_name" $quality_command \
                    "$const" "$encrypt" &
                pid=$!

                $JQ_FILE '.channels += [
                    {
                        "pid":'"$pid"',
                        "status":"on",
                        "stream_link":"'"$stream_link"'",
                        "output_dir_name":"'"$output_dir_name"'",
                        "playlist_name":"'"$playlist_name"'",
                        "seg_dir_name":"'"$SEGMENT_DIRECTORY"'",
                        "seg_name":"'"$seg_name"'",
                        "seg_length":'"$seg_length"',
                        "seg_count":'"$seg_count"',
                        "video_codec":"'"$VIDEO_CODEC"'",
                        "audio_codec":"'"$AUDIO_CODEC"'",
                        "video_audio_shift":"",
                        "quality":"'"$quality"'",
                        "bitrates":"'"$bitrates"'",
                        "const":"'"$const_yn"'",
                        "encrypt":"'"$encrypt_yn"'",
                        "key_name":"'"$key_name"'",
                        "input_flags":"'"$FFMPEG_INPUT_FLAGS"'",
                        "output_flags":"'"$FFMPEG_FLAGS"'",
                        "channel_name":"'"$channel_name"'"
                    }
                ]' "$CHANNELS_FILE" > "$CHANNELS_TMP"
                mv "$CHANNELS_TMP" "$CHANNELS_FILE"
                action="add"
                SyncFile
            fi

            echo -e "$info 添加频道成功..." && echo
        fi
    fi
fi