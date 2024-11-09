#!/bin/bash

# Usage: ./script.sh <registry> <image> <user> <password> <levels>
# Подключение к реестру и удаление устаревших образов

registry=$1
image=$2
user=$3
password=$4
levels=${5:-5}  # Использовать 5 тегов по умолчанию, если не указано

# Функция для сортировки тегов по дате и удаления устаревших
delete_old_tags() {
    local registry=$1
    local image=$2
    local user=$3
    local password=$4
    local levels=$5

    # Получение токена
    local token_url
    token_url=$(curl -s -u "$user:$password" "https://${registry}/auth?service=cr.selcloud.ru&scope=repository:${image}:pull,push,delete")
#    echo "Token URL Response: $token_url"

    local token
    token=$(echo "$token_url" | jq -r '.token')

    if [[ -z "$token" || "$token" == "null" ]]; then
        echo "Failed to retrieve a token."
        exit 1
    fi

    # Получение всех тегов
    local tags_json
    tags_json=$(curl -s -H "Authorization: Bearer $token" "https://${registry}/v2/${image}/tags/list")

    local tags
    tags=$(echo "$tags_json" | jq -r '.tags // [] | .[]')

    declare -A tags_and_dates

    # Get creation date for each tag
    for tag in $tags; do
        # Get manifest to retrieve config.digest
        local manifest
        manifest=$(curl -s -H "Authorization: Bearer $token" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -X GET "https://${registry}/v2/${image}/manifests/$tag")

        local config_digest
        config_digest=$(echo "$manifest" | jq -r '.config.digest')


        if [[ -n "$config_digest" && "$config_digest" != "null" ]]; then
            # Get blob using config.digest to find creation date
            local blob
            blob=$(curl -s -H "Authorization: Bearer $token" -X GET "https://${registry}/v2/${image}/blobs/$config_digest")

            local created_time
            created_time=$(echo "$blob" | jq -r '.created')
            if [[ -n "$created_time" && "$created_time" != "null" ]]; then
                # Convert date to UNIX timestamp for sorting
                local created_timestamp
                created_timestamp=$(date --date="$created_time" +%s)
                tags_and_dates[$tag]=$created_timestamp
            else
                echo "Failed to retrieve creation date for tag $tag"
            fi
        else
            echo "Failed to retrieve config.digest for tag $tag"
        fi
    done

    # Sort tags by creation date
    sorted_tags=($(for tag in "${!tags_and_dates[@]}"; do echo "$tag ${tags_and_dates[$tag]}"; done | sort -k2 -n | awk '{print $1}'))

    # Calculate total tags and those to delete
    local total_tags=${#sorted_tags[@]}
    local tags_to_delete_count=$((total_tags - levels))

    if [[ $tags_to_delete_count -le 0 ]]; then
        echo "No tags to delete."
        return
    fi

    echo "Deleting $tags_to_delete_count tags out of $total_tags total."

    # Delete excess tags
    for ((i=0; i < tags_to_delete_count; i++)); do
        tag=${sorted_tags[i]}
        echo "Deleting tag: $tag"

        local digest
        digest=$(curl -s -I -H "Authorization: Bearer $token" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" "https://${registry}/v2/${image}/manifests/${tag}" | grep -i 'docker-content-digest' | awk -F': ' '{print $2}' | tr -d '\r')

        if [[ -n $digest ]]; then
            response=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Authorization: Bearer $token" "https://${registry}/v2/${image}/manifests/$digest")

            if [[ "$response" -eq 202 ]]; then
                echo "Successfully deleted tag: $tag"
            else
                echo "Failed to delete tag: $tag"
            fi
        fi
    done
}

delete_old_tags "$registry" "$image" "$user" "$password" "$levels"