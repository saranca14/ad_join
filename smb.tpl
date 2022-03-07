[global]
        workgroup = ${WORKGROUP}
        client signing = yes
        client use spnego = yes
        kerberos method = secrets and keytab
        log file = /var/log/samba/%m.log
        realm = ${REALM}
        security = ads
        netbios name = ${HNAME}
        disable netbios = yes
        log file = /var/log/samba/log.%m
         max log size = 50
         load printers = yes
         cups options = raw

[homes]
        comment = Home Directories
        browseable = no
        writable = yes

[printers]
        comment = All Printers
        path = /var/spool/samba
        browseable = no
        guest ok = no
        writable = no
        printable = yes