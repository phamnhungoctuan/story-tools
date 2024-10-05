#!/usr/bin/env bash
set -euo pipefail

# Minimum hardware requirements
MIN_CPU_CORES=4
MIN_RAM_MB=16000  # 16GB in MB
MIN_DISK_GB=200   # 200GB in GB

# Functions

check_system_requirements() {
    echo "Checking system requirements..."

    # Get CPU cores
    local cpu_cores=$(grep -c ^processor /proc/cpuinfo)
    # Get available RAM in MB
    local ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    # Get available disk space in GB
    local disk_gb=$(df --output=avail / | tail -1 | awk '{print $1/1024/1024}')

    # Check if the system meets the requirements
    if (( cpu_cores < MIN_CPU_CORES )); then
        echo "Insufficient CPU cores: ${cpu_cores} cores available, but ${MIN_CPU_CORES} cores required."
        return 1
    fi

    if (( ram_mb < MIN_RAM_MB )); then
        echo "Insufficient RAM: ${ram_mb} MB available, but ${MIN_RAM_MB} MB required."
        return 1
    fi

    if (( $disk_gb < $MIN_DISK_GB )); then
        echo "Insufficient disk space: ${disk_gb} GB available, but ${MIN_DISK_GB} GB required."
        return 1
    fi

    echo "System meets the minimum hardware requirements."

    printf "%-12s %-10s\n" "Resource" "Minimum Requirement"
    printf "%-12s %-10s\n" "--------" "-------------------"
    printf "%-12s %-10s\n" "CPU" "4 Cores"
    printf "%-12s %-10s\n" "RAM" "16 GB"
    printf "%-12s %-10s\n" "Disk" "200 GB"
    printf "%-12s %-10s\n" "Bandwidth" "25 MBit/s"
}

download_and_extract() {
    local url=$1
    local output=$2
    if [ -f "$output" ]; then
        echo "$output already exists. Skipping download."
    else
        wget -qO "$output" "$url"
        tar xf "$output"
        cp story*/story /usr/local/bin
        rm -rf story*/ "$output"
    fi
}

check_command_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed. Exiting."
        exit 1
    fi
}

mainMenu() {
    echo -e "\033[36m""Story Validator Tools""\e[0m"
    echo "0. Check system hardware requirements"
    echo "1. Install Story Node"
    echo "2. Update Story Consensus"
    echo "3. Update Story Geth"
    echo "4. Create validator"
    echo "5. Get latest block height"
    echo "6. Get Validator dashboard link"
    echo "7. Get Validator Public and Private Key"
    echo "8. Get faucet"
    echo "q. Quit"
}

installStoryConsensus() {
    echo "Getting Story Consensus..."
    download_and_extract $(curl -s https://api.github.com/repos/piplabs/story/releases/latest | grep 'body' | grep -Eo 'https?://[^ ]+story-linux-amd64[^ ]+' | sed 's/......$//') story.tar.gz
    check_command_success "Story Consensus download"
}

installStoryGeth() {
    echo "Getting Story Geth..."
    download_and_extract $(curl -s https://api.github.com/repos/piplabs/story-geth/releases/latest | grep 'body' | grep -Eo 'https?://[^ ]+geth-linux-amd64[^ ]+' | sed 's/......$//') story-geth.tar.gz
    check_command_success "Story Geth download"
}

freshInstallSecondPart() {
    installStoryGeth
    read -p "Please enter your moniker: " moniker
    story init --network iliad --moniker "$moniker"
    createStoryConsensusServiceFile
    createStoryGethServiceFile
    echo "Adding Peers"
    sed -i.bak -e "s/^persistent_peers *=.*/persistent_peers = \"$(curl -sS https://story-rpc.oreonserv.com/net_info | jq -r '.result.peers[] | "\(.node_info.id)@\(.remote_ip):\(.node_info.listen_addr)"' | awk -F ':' '{print $1":"$(NF)}' | paste -sd, -)\"/" "$HOME/.story/story/config/config.toml"
    echo "Restarting the services"
    sudo systemctl restart story story-geth
}

createServiceFile() {
    local service_name=$1
    local exec_command=$2

    sudo tee "/etc/systemd/system/${service_name}.service" > /dev/null <<EOF
    [Unit]
    Description=${service_name} Service
    After=network.target

    [Service]
    User=root
    ExecStart=$exec_command
    Restart=on-failure
    RestartSec=3
    LimitNOFILE=4096

    [Install]
    WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$service_name"
    sudo systemctl start "$service_name"
}

createStoryConsensusServiceFile() {
    createServiceFile "story" "/usr/local/bin/story run"
}

createStoryGethServiceFile() {
    createServiceFile "story-geth" "/usr/local/bin/geth --iliad --syncmode full --http --http.api eth,net,web3,engine --http.vhosts '*' --http.addr 0.0.0.0 --http.port 8545 --ws --ws.api eth,web3,net,txpool --ws.addr 0.0.0.0 --ws.port 8546"
}

updateComponent() {
    local component=$1
    local service_name=$2
    local install_function=$3

    latest_version=$(curl -s https://api.github.com/repos/piplabs/$component/releases/latest | grep tag_name | cut -d\" -f4)
    echo "Latest $component version is: $latest_version"
    installed_version=$($component -v)
    echo "Installed $component version: $installed_version"

    read -p "Are you sure you want to update? (y/n) " yn
    case $yn in
        [yY])
            echo "Updating $component..."
            sudo systemctl stop "$service_name"
            rm "/usr/local/bin/$component"
            $install_function
            sudo systemctl start "$service_name"
            echo "Done updating $component!"
            ;;
        *)
            echo "Exiting update process for $component."
            ;;
    esac
}

installMenu() {
    latestConsVersion=$(curl -s https://api.github.com/repos/piplabs/story/releases/latest | grep tag_name | cut -d\" -f4)
    secondChoiceVersion=$(curl -s "https://api.github.com/repos/piplabs/story/tags" | grep -oP '"name": "\K[^"]+' | sed -n '2p')

    PS3="Select an option: "
    select subopt in "Install version $latestConsVersion - Latest" "Install version $secondChoiceVersion" "Back"; do
        case $subopt in
            "Install version $latestConsVersion - Latest")
                installStoryConsensus
                freshInstallSecondPart
                ;;
            "Install version $secondChoiceVersion")
                installStoryConsensus
                freshInstallSecondPart
                ;;
            "Back")
                break
                ;;
            *)
                echo "Invalid option $REPLY"
                ;;
        esac
    done
}

while true; do
    echo
    mainMenu
    echo
    read -ep "Enter the number of the option you want: " CHOICE
    echo

    case "$CHOICE" in
        "0") # Check system hardware requirements
            check_system_requirements
            ;;
        "1") # Install Story node
            installMenu
            ;;
        "2") # Update Story Consensus
            updateComponent "story" "story" installStoryConsensus
            ;;
        "3") # Update Story Geth
            updateComponent "geth" "story-geth" installStoryGeth
            ;;
        "4") # Create the validator
            echo "This will stake 0.5 IP to your validator, make sure you have some in your wallet."
            read -s -p "Please enter your private key: " key
            echo
            story validator create --stake 500000000000000000 --private-key "$key"
            ;;
        "5") # Get latest block height
            curl -s localhost:26657/status | jq .result.sync_info.latest_block_height
            ;;
        "6") # Get Validator dashboard link
            address=$(cat ~/.story/story/config/priv_validator_key.json | grep address | cut -d\" -f4)
            echo "https://testnet.story.explorers.guru/validator/$address"
            ;;
        "7") # Get Validator Public and Private Key
            story validator export --export-evm-key
            cat "$HOME/.story/story/config/private_key.txt"
            ;;
        "8") # Get faucet
            echo "https://story.faucetme.pro/"
            ;;
        "q") # quit the script
            exit
            ;;
        *)
            echo "Invalid option"
            ;;
    esac
done
