#!/usr/bin/env bash
# version 2025-04-30_17:35

#Set ip addresses and password for root user
osv_1_ip="10.44.100.11"
osv_2_ip="10.45.100.12"
osv_1_user="root"
osv_2_user="root"
osv_1_password="T@R63dis"
osv_2_password="T@R63dis"

files_dir="/root/pce_upgrade/upload_files"
ssh_hosts_file="/root/.ssh/known_hosts"

# timestamped output
output() {
	echo
    printf "[img_upgrade_script.sh %s]  %s\n" "$(date +%T)" "$@"
}

proceed () {
	while true; do
		read -p "[img_upgrade_script.sh user_input] Proceed? (y/n): " answer
		case $answer in
			[Yy]* ) break;;
			[Nn]* ) echo "Exiting."; exit 1; echo;;
		esac
	done
}

output "Reminder : get machine images for ESRP/PCE nodes before IMG upgrade"
proceed

output "Checking prerequisites (dir, expect, sshpass)"
if [ ! -d "$files_dir" ]; then
  echo "Directory $files_dir is missing."
  mkdir $files_dir
  echo "Creating dir $files_dir. Please upload ISO & RPM files anr re-run script."
  exit 1
else
  echo "Found directory $files_dir"
fi
command -v expect || { echo "Please install expect package"; exit 1; }
command -v sshpass || { echo "Please install sshpass package"; exit 1; }

#check number of files locally: 1 iso - 1 rpm | get rpm filename
output "Checking files in ${files_dir}"
num_iso_files=$(ls ${files_dir} | grep '.iso' | wc -l)
num_rpm_files=$(ls ${files_dir} | grep '.rpm' | wc -l)
num_files=$(ls ${files_dir} | wc -l)
if [ "$num_files" -ne 2 ]; then echo "Only 2 files must be in ${files_dir}, ISO & rpm exiting."; exit 1; fi
if [ "$num_iso_files" -ne 1 ]; then echo "Only 1 ISO file must be in ${files_dir}, exiting."; exit 1; fi
if [ "$num_rpm_files" -ne 1 ]; then echo "Only 1 rpm file must be in ${files_dir}, exiting."; exit 1; fi
iso_filename=$(ls ${files_dir} | grep '.iso')
rpm_filename=$(ls ${files_dir} | grep '.rpm')
output "Found IMG file : ${iso_filename}"
output "Found rpm file : ${rpm_filename}"

#set up up ssh keys 
output "Setting up ssh keys for node 1 : $osv_1_ip"
ssh-keygen -R $osv_1_ip > /dev/null 2>&1
ssh-keyscan -H $osv_1_ip >> $ssh_hosts_file 2>&1
output "Setting up ssh keys for node 2 :  $osv_2_ip"
ssh-keygen -R $osv_2_ip > /dev/null 2>&1
ssh-keyscan -H $osv_2_ip >> $ssh_hosts_file  2>&1

#Check state that is 4 4
output "Running srxqry on $osv_1_ip"
sshpass -p "$osv_1_password" ssh -o LogLevel=error root@"$osv_1_ip" 'srxqry'
output "Check srxqry above and proceed (state 4 4, all processes Up)"
#output "If needed run rapidstat manually (~srx/bin/RapidStat -b)"
proceed
echo

#Ask for rapidstat
while true; do
	read -p "[img_upgrade_script.sh user_input] Do you want to run RapidStat? (y/n): " answer
	case $answer in
		[Yy]* ) sshpass -p "$osv_1_password" ssh -o LogLevel=error root@"$osv_1_ip" '~srx/bin/RapidStat -b'; output "Check RapidStat results above and proceed"; proceed; break;;
		[Nn]* ) break;;
	esac
done

#remove any existing iso and rpm files > rm -rf /repository/upload/*
cleanup_rep_upload () {
	output "Node $1 - Files under $2:/repository/upload/"
	sshpass -p "$3" ssh -o LogLevel=error root@"$2" 'ls -l /repository/upload/'
	output "Removing all files from from $2:/repository/upload/"
	sshpass -p "$3" ssh -o LogLevel=error root@"$2" 'rm -rf /repository/upload/*'
	output "Running df -h on node $1 - $2"
	sshpass -p "$3" ssh -o LogLevel=error root@"$2" 'df -h'
}
cleanup_rep_upload 1 $osv_1_ip $osv_1_password
cleanup_rep_upload 2 $osv_2_ip $osv_2_password

#upload files to both nodes
# idea 1 : sshpass -p 'sshpassword' rsync --progress -avz -e ssh test@remhost:~/something/ ~/bak/
# idea 2 : /usr/bin/rsync -ratlz --rsh="/usr/bin/sshpass -p password ssh -o StrictHostKeyChecking=no -l username" src_path  dest_path
# idea 3 :
#    upload_files () {
#    output "Transfer $3 to $1"
#    expect << EOF 
#    #comment line below to enable full output
#    #log_user 0
#    spawn rsync -avz -e ssh ${files_dir}/$3 root@$1:/repository/upload/
#    #spawn scp ${files_dir}/$3 root@$1:/repository/upload/
#    set timeout 180
#    expect "assword:"
#    sleep 7
#    send "${2}\n"
#    expect eof
#    EOF
#    echo
#    }
# idea 4 :
upload_files () {
	output "Transferring $3 to $1"
	sshpass -p "${2}" scp -o LogLevel=error ${files_dir}/$3 root@$1:/repository/upload/
}
upload_files $osv_1_ip $osv_1_password $iso_filename
upload_files $osv_1_ip $osv_1_password $rpm_filename
upload_files $osv_2_ip $osv_2_password $iso_filename
upload_files $osv_2_ip $osv_2_password $rpm_filename
sleep 5

# Check sha256sum checksums
output "Calculating sha256sum checksums for all files"
check_sha256sum () {
	chksm_local=$(sha256sum ${files_dir}/$1 )
	chksm_n1=$(sshpass -p "$osv_1_password" ssh -o LogLevel=error root@"$osv_1_ip" "sha256sum /repository/upload/$1")
	chksm_n2=$(sshpass -p "$osv_2_password" ssh -o LogLevel=error root@"$osv_2_ip" "sha256sum /repository/upload/$1")
	echo "$chksm_local "
	echo "$chksm_n1 on $osv_1_ip" 
	echo "$chksm_n2 on $osv_2_ip"
}
check_sha256sum $iso_filename
check_sha256sum $rpm_filename
output "Check checksums above and proceed"
proceed

#install latest migration toolkit
install_rpm (){ 
	output "Check if migration toolkit is installed on $2"
	sshpass -p "$3" ssh -o LogLevel=error root@$2 "rpm -qa | grep -i UNSPmigration"
	sleep 1
	output "Remove migration toolkit from $2"	
	sshpass -p "$3" ssh -o LogLevel=error root@$2 "rpm -e UNSPmigration"
	sleep 1
	output "Install migration toolkit on $2"
	sshpass -p "$3" ssh -o LogLevel=error root@$2 "rpm -ivh --replacefiles --replacepkgs /repository/upload/$1"
	sleep 1
}
install_rpm $rpm_filename $osv_1_ip $osv_1_password 
install_rpm $rpm_filename $osv_2_ip $osv_2_password 

#create node.cfg.primary & node.cfg.secondary
output "Copying node.cfg.primary /repository/upload on node 1 : $osv_1_ip"
sshpass -p "$osv_1_password" ssh -o LogLevel=error root@"$osv_1_ip" 'cp /repository/config/V9.00.01.ALL.12/node.cfg /repository/upload/node.cfg.primary'
output "Copying node.cfg.secondary to /repository/upload on node 2 : $osv_2_ip"
sshpass -p "$osv_2_password" ssh -o LogLevel=error root@"$osv_2_ip" 'cp /repository/config/V9.00.01.ALL.12/node.cfg /repository/upload/node.cfg.secondary'

#check /repository/upload folder
output "Checking files on /repository/upload on node 1 : $osv_1_ip"
sshpass -p "$osv_1_password" ssh -o LogLevel=error root@"$osv_1_ip" 'ls -l /repository/upload/'
output "Checking files on /repository/upload on node 2 : $osv_2_ip"
sshpass -p "$osv_2_password" ssh -o LogLevel=error root@"$osv_2_ip" 'ls -l /repository/upload/'

#Check that no upgrade is running
output "Running upgrade8k -s to verify no upgrade is running"
sshpass -p "$osv_1_password" ssh -o LogLevel=error root@"$osv_1_ip" 'upgrade8k -s'
output "Check output above to verify there is no upgrade running"
echo "Select YES to proceed with 'upgrade8k -quiet -live' on this script via this linux machine (ssh session) until node 1 reboots."
echo "Select NO  to end this script and manually run the upgrade command 'upgrade8k -quiet -live' directly on the instance console"
proceed

#Run upgrade command : upgrade8k -quiet -live
output "Sending upgrade command @ node 1 : $osv_1_ip"
sshpass -p "$osv_1_password" ssh -o LogLevel=error root@"$osv_1_ip" 'upgrade8k -quiet -live'

#Node 1 reboots, ssh disconnects.
output "Done. There are no more automated steps from this script"

echo; echo; echo
echo "Notes on upgrade8k process :"
echo " - Live upgrade (upgrade8k -quiet -live) usually takes 2 hours"
echo " - To check upgrade status, run upgrade8k -s"
echo " - To verify upgrade, check on both nodes: /repository/upgrade8k-timing & /log/prepare8k.log"
echo " - When completed run check srxqry (srxqry -v) & rapidstat (~srx/bin/RapidStat -b)"
echo " - https://atos-ps.atlassian.net/wiki/spaces/OVM/pages/43363646/Instructions+for+OSV+Live+Upgrade+using+toolkit#InstructionsforOSVLiveUpgrade(usingtoolkit)-HowtoperformanOSVLiveUpgrade"
echo


#postupgrade
#srxqqry -v
#pkgversion -f
#Rapidstat -b
#upgrade8k -s
#/log/prepare8k.log
#/repository/upgrade8k-timing
