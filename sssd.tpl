[sssd]
services = nss, pam
config_file_version = 2
reconnection_retries = 3
sbus_timeout = 30
domains = ${DOMAINS}

[nss]
filter_groups = root
filter_users = root
reconnection_retries = 3

[pam]
reconnection_retries = 3

[domain/${DOM_VAR}]
id_provider = ad
cache_credentials = True
access_provider = simple
ldap_id_mapping = False
use_fully_qualified_names = False
ad_domain = ${AD_DOMAIN}
enumerate = false
ldap_deref_threshold = 0
ldap_use_tokengroups = False
debug_level = 3
[autofs]