#!/usr/bin/env bash

docker compose ls --format json | \
sed 's/^\[//;s/\]$//' | \
sed 's/},{/}\n{/g' | \
sed -n 's/.*"Name":"\([^"]*\)".*"ConfigFiles":"\([^"]*\)".*/\1|\2/p' | \
while read -r line; do
    project_name="${line%%|*}"
    config_files="${line#*|}"
    
    IFS=',' read -ra FILES <<< "$config_files"
    
    compose_args="compose"
    for file in "${FILES[@]}"; do
        compose_args="$compose_args -f $file"
    done
    
    docker $compose_args ps --format '{{.Image}}|{{.Name}}|{{.State}}' | grep -i "postgres" | while read -r container_line; do
        image="${container_line%%|*}"
        rest="${container_line#*|}"
        name="${rest%%|*}"
        state="${rest#*|}"

        first_config="${FILES[0]}"
        project_dir=$(dirname "$first_config")
        env_file="$project_dir/.env"

        if [ -f "$env_file" ]; then
            echo "  Env file: $env_file"

            db_name=$(grep "^DB=" "$env_file" | cut -d '=' -f2- | sed 's/^"//;s/"$//;s/^\x27//;s/\x27$//')
            db_user=$(grep "^DB_USER=" "$env_file" | cut -d '=' -f2- | sed 's/^"//;s/"$//;s/^\x27//;s/\x27$//')
            db_pass=$(grep "^DB_PASSWORD=" "$env_file" | cut -d '=' -f2- | sed 's/^"//;s/"$//;s/^\x27//;s/\x27$//')
            
            if [ -n "$db_name" ] && [ -n "$db_user" ] && [ -n "$db_pass" ]; then
                echo "  DB Name: $db_name"
                echo "  DB User: $db_user"
                
                backup_file="$HOME/backups/$project_name/${db_name}_$(date +%Y%m%d).sql"

                backup_cmd="docker exec -e PGPASSWORD=\"$db_pass\" $name pg_dump -U \"$db_user\" \"$db_name\" > \"$backup_file\""
                
                # eval "$backup_cmd"

                # Send to backup service

            else
                echo "$project_dir: Missing DB, DB_USER, or DB_PASSWORD in .env"
            fi
        else
            echo "$project_dir: No .env file found"
        fi
    done
done
