#!/bin/bash

#exitcode_description
#exit 0=success 
#exit 1=sssd_failed  
#exit 2=testjoin/klist command failed 
#exit 3=centrify_client
#exit 4=id_check failed

#Declare variables
HNAME=`hostname`
ad_admin=$(awk '/ad_server/ {print $3}' /etc/sssd/sssd.conf | xargs echo -n)
password_server=$(awk '/password server/ {print $4}' /etc/samba/smb.conf | xargs echo -n)
len=`echo $HNAME |awk '{print length}'`
ADVERSION=`adinfo -v`
DOMAINTEST=$(net ads testjoin -k)
REGION=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | awk -F'"' '/\"region\"/ { print $4 }'`
INSTANCE_ID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
VAULT_TOKEN=s.RKcgzmvY19RrgxbOUKtQv5V0
domain_pass=$(curl \
                -H "X-Vault-Token: $VAULT_TOKEN" \
                -H "Content-Type: text/html" \
                -X GET \
                https://vault.10006.elluciancloud.com/v1/secret/data/cloud/infra/platform/ad-passwords/$REGION |
                sed -e 's/[{}]/''/g' |
                awk -v k="text" '{n=split($0,a,","); for (i=1; i<=n; i++) print a[i]}' |
                awk -F'"' '/\"data\"/ { print $8 }')
TAG_CHECK=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" --region $REGION |  awk '/"Value": "Resource"/ {print $2}' | tr -d '"' | tr -d ',')

#Ths function is to create success/fail file; This will be used later by bigfix fixlet relevance
join_success() {
    touch /tmp/ad_connect_success
    rm -rf /tmp/ad_connect_fail
}
#Ths function is to create success/fail file; This will be used later by bigfix fixlet relevance.
join_fail() {
    touch /tmp/ad_connect_fail
    rm -rf /tmp/ad_connect_success
}

#This function checks if backup is already present for conf files, If not creates new backup.
create_backup() {
    echo "Checking backup status of configuration files sssd.conf, kerb5.conf, smb.conf"
    #Create Backup conf file for sssd.conf, kerb5.conf, smb.conf
    for i in /etc/sssd/sssd.conf /etc/krb5.conf /etc/samba/smb.conf
    do
        if [ -e ${i}.bck ]
        then
            echo "${i}.bck backup file already exists"
            echo "Skipping backup process"
        else
            echo "$i Backup file doesn't exist, So creating $i.bck"
            \cp -fR $i $i.bck
            echo "Created backup $i.bck successfully"
            sleep 5
        fi
    done
    }

#This function clears cache and leaves the domain.
leave_domain() {
    echo "Leaving the AD domain"
    #Clear cache before leaving domain
    service sssd stop
    rm -rf /var/lib/sss/db/*
    kdestroy
    mv -f /etc/krb5.keytab /etc/krb5.keytab.backup
    #Leave the domain
    net ads leave -U svc_rheljoin%$domain_pass
    sleep 5
}

#This function replaces the existing conf files with standard configuration template. This removes hardcoded AD server parameters from configuration file.
modify_conf() {    
    echo "Changing the conf files"
    sleep 5
    #Replace the conf files with standard conf templates:
    krb5_file=krb5.tpl
    smb_file=smb.tpl
    sssd_file=sssd.tpl
    config_file=variables.conf

    . "${config_file}"
    eval "echo \"$(cat "${krb5_file}")\"" > /etc/krb5.conf
    echo "modified the krb5.conf"
    sleep 5
    . "${config_file}"
    eval "echo \"$(cat "${smb_file}")\"" > /etc/samba/smb.conf
    echo "modified the smb.conf"
    sleep 5
    . "${config_file}"
    eval "echo \"$(cat "${sssd_file}")\"" > /etc/sssd/sssd.conf
    echo "modified the sssd.conf"
    sleep 5
}

#This function executes authconfig command and starts sssd service after client is joined to domain.
auth_config() {
    if [[ $(grep 6 /etc/redhat-release) ]]
    then
        authconfig --update --enablesssd --enablesssdauth --enablemkhomedir
        echo "authconfig command status $?"
        sleep 10
    elif [[ $(grep "CentOS Linux release 7" /etc/redhat-release) ]]
    then
         yum remove authconfig -y > /dev/null 2>&1
         sleep 5
         yum install authconfig -y > /dev/null 2>&1
         sleep 5
         authconfig --update --enablesssd --enablesssdauth --enablemkhomedir
         echo "authconfig command status $?"
         sleep 10
    else
        echo "OS version: Red Hat Enterprise Linux Server release 7"
        echo "Skipping authconfig command"
        sleep 10
    fi
    service sssd start
    echo "sssd status is $?"
    if [ $(service sssd status > /dev/null 2>&1;echo $?) == 0 ]
    then
        echo "sssd service started successfully"
    else
        echo "sssd service failed to start"
    fi
}

#This function checks the status of sssd service and keytab file.
check_sssd() {
    if [ -f /etc/krb5.keytab ]
    then
        echo "keytab file present, Trying to restart sssd service"
        service sssd restart
    else
        echo "Creating keytab file from backup file"
        cp /etc/krb5.keytab.backup /etc/krb5.keytab
        service sssd restart
    fi
    if [ $(service sssd status > /dev/null 2>&1;echo $?) == 0 ]
    then
        join_success
        exit 0
    else
        join_fail
        exit 1
    fi 
}

#This function joins the domain.
join_domain() {
    echo "Leaving the domain and clears cache before clean re-join"
    leave_domain
    echo "Rejoining domain using kinit"
    #Rejoin the server to AD
    kinit svc_rheljoin <<<$domain_pass
    retVal=$?
    if [ $retVal -eq 127 ]
    then
        echo "krb5-workstation package is missing"
        yum install krb5-workstation -y
        kinit svc_rheljoin <<<$domain_pass
        echo "Join kinit status $?"
    else
        echo "Join kinit status $retVal"
    fi
    sleep 10
    net ads join -k 2> /dev/null
    echo "Join AD status $?"
    sleep 10
    echo "Calling authconfig function to perform authconfig commands"
    auth_config
}

#Function to check id
id_check() {
    if [ "$(id svc_rheljoin > /dev/null 2>&1;echo $?)" == 0 ]
    then
        echo "id check is verified"
        echo "Script execution completed successfully"
    else
        echo "id command not successful after first run, Calling join_domain function one more time"
        join_domain
    fi
}

# __main__
if [[ "$ADVERSION" =~ 'adinfo' || $len -lt 8 || "$TAG_CHECK" == "Resource" ]];
then
    echo "Identified as Centrify Client"
    exit 3
else
    echo "Identified as SSSD Client"
    echo "Checking configuration files sssd.conf, krb5.conf, smb.conf"
    if [ -z "$ad_admin" ] && [ -z "$password_server" ]
    then
            echo "Configuration files are already in standard format"
            echo "Checking AD Join status"
            if [[ $(net ads testjoin -k) = "Join is OK" ]] && [[ $(id svc_rheljoin > /dev/null 2>&1;echo $?) == 0 ]]
            then
                echo "Client machine is already joined to AD"
                if [ $(service sssd status > /dev/null 2>&1;echo $?) == 0 ]
                then
                    echo "SSSD service is up and running"
                else
                    echo "SSSD service is in stopped state, Trying to start SSSD service"
                    check_sssd
                fi
            else
                echo "AD status is disconnected"
                echo "Trying to rejoin AD"
                create_backup
                join_domain
                id_check
            fi
    else
            echo "Hardcoded AD parameters present in conf files"
            echo "Converting configuration files into standard format"
            create_backup           
            modify_conf
            join_domain
            id_check
    fi
fi
sleep 10
#Condition to output the success/fail file which will be used by bigfix later.
if [[ "$(net ads testjoin -k)" = "Join is OK"  &&  "$(id svc_rheljoin > /dev/null 2>&1;echo $?)" == 0 ]]
then
    if [ $(service sssd status > /dev/null 2>&1;echo $?) == 0 ]
    then
        join_success
        exit 0
    else
        join_fail
        exit 1
    fi
else
    join_fail
    exit 2
fi