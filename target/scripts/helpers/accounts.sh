#! /bin/bash
# Support for Postfix accounts managed via Dovecot

# It looks like the DOMAIN in below logic is being stored in /etc/postfix/vhost,
# even if it's a value used for Postfix `main.cf:mydestination`, which apparently isn't good?
# Only an issue when $myhostname is an exact match (eg: bare domain FQDN).

function _create_accounts
{
  : >/etc/postfix/vmailbox
  : >/etc/dovecot/userdb

  if [[ -f /tmp/docker-mailserver/postfix-accounts.cf ]] && [[ ${ENABLE_LDAP} -ne 1 ]]
  then
    _notify 'inf' "Checking file line endings"
    sed -i 's|\r||g' /tmp/docker-mailserver/postfix-accounts.cf

    _notify 'inf' "Regenerating postfix user list"
    echo "# WARNING: this file is auto-generated. Modify /tmp/docker-mailserver/postfix-accounts.cf to edit the user list." > /etc/postfix/vmailbox

    # checking that /tmp/docker-mailserver/postfix-accounts.cf ends with a newline
    # shellcheck disable=SC1003
    sed -i -e '$a\' /tmp/docker-mailserver/postfix-accounts.cf

    chown dovecot:dovecot /etc/dovecot/userdb
    chmod 640 /etc/dovecot/userdb

    sed -i -e '/\!include auth-ldap\.conf\.ext/s/^/#/' /etc/dovecot/conf.d/10-auth.conf
    sed -i -e '/\!include auth-passwdfile\.inc/s/^#//' /etc/dovecot/conf.d/10-auth.conf

    # creating users ; 'pass' is encrypted
    # comments and empty lines are ignored
    local LOGIN PASS USER_ATTRIBUTES
    while IFS=$'|' read -r LOGIN PASS USER_ATTRIBUTES
    do
      # Setting variables for better readability
      USER=$(echo "${LOGIN}" | cut -d @ -f1)
      DOMAIN=$(echo "${LOGIN}" | cut -d @ -f2)

      # test if user has a defined quota
      if [[ -f /tmp/docker-mailserver/dovecot-quotas.cf ]]
      then
        declare -a USER_QUOTA
        IFS=':' read -r -a USER_QUOTA < <(grep "${USER}@${DOMAIN}:" -i /tmp/docker-mailserver/dovecot-quotas.cf)

        if [[ ${#USER_QUOTA[@]} -eq 2 ]]
        then
          USER_ATTRIBUTES="${USER_ATTRIBUTES:+${USER_ATTRIBUTES} }userdb_quota_rule=*:bytes=${USER_QUOTA[1]}"
        fi
      fi

      if [[ -z ${USER_ATTRIBUTES} ]]
      then
        _notify 'inf' "Creating user '${USER}' for domain '${DOMAIN}'"
      else
        _notify 'inf' "Creating user '${USER}' for domain '${DOMAIN}' with attributes '${USER_ATTRIBUTES}'"
      fi

      echo "${LOGIN} ${DOMAIN}/${USER}/" >> /etc/postfix/vmailbox
      # Dovecot's userdb has the following format
      # user:password:uid:gid:(gecos):home:(shell):extra_fields
      echo \
        "${LOGIN}:${PASS}:5000:5000::/var/mail/${DOMAIN}/${USER}::${USER_ATTRIBUTES}" \
        >>/etc/dovecot/userdb

      mkdir -p "/var/mail/${DOMAIN}/${USER}"

      # copy user provided sieve file, if present
      if [[ -e "/tmp/docker-mailserver/${LOGIN}.dovecot.sieve" ]]
      then
        cp "/tmp/docker-mailserver/${LOGIN}.dovecot.sieve" "/var/mail/${DOMAIN}/${USER}/.dovecot.sieve"
      fi

      echo "${DOMAIN}" >> /tmp/vhost.tmp
    done < <(grep -v "^\s*$\|^\s*\#" /tmp/docker-mailserver/postfix-accounts.cf)

    _create_dovecot_alias_dummy_accounts
  fi
}

# Required when using Dovecot Quotas to avoid blacklisting risk from backscatter
# Note: This is a workaround only suitable for basic aliases that map to single real addresses,
# not multiple addresses (real accounts or additional aliases), those will not work with Postfix
# `quota-status` policy service and remain at risk of backscatter.
#
# see https://github.com/docker-mailserver/docker-mailserver/pull/2248#issuecomment-953313852
# for more details on this method
function _create_dovecot_alias_dummy_accounts
{
  if [[ -f /tmp/docker-mailserver/postfix-virtual.cf ]] && [[ ${ENABLE_QUOTAS} -eq 1 ]]
  then
    # adding aliases to Dovecot's userdb
    # ${REAL_FQUN} is a user's fully-qualified username
    local ALIAS REAL_FQUN
    while read -r ALIAS REAL_FQUN
    do
      # ignore comments
      [[ ${ALIAS} == \#* ]] && continue

      # alias is assumed to not be a proper e-mail
      # these aliases do not need to be added to Dovecot's userdb
      [[ ! ${ALIAS} == *@* ]] && continue

      # clear possibly already filled arrays
      # do not remove the following line of code
      unset REAL_ACC USER_QUOTA
      declare -a REAL_ACC USER_QUOTA

      local REAL_USERNAME REAL_DOMAINNAME
      REAL_USERNAME=$(cut -d '@' -f 1 <<< "${REAL_FQUN}")
      REAL_DOMAINNAME=$(cut -d '@' -f 2 <<< "${REAL_FQUN}")

      if ! grep -q "${REAL_FQUN}" /tmp/docker-mailserver/postfix-accounts.cf
      then
        _notify 'inf' "Alias '${ALIAS}' is non-local (or mapped to a non-existing account) and will not be added to Dovecot's userdb"
        continue
      fi

      _notify 'inf' "Adding alias '${ALIAS}' for user '${REAL_FQUN}' to Dovecot's userdb"

      # ${REAL_ACC[0]} => real account name (e-mail address) == ${REAL_FQUN}
      # ${REAL_ACC[1]} => password hash
      # ${REAL_ACC[2]} => optional user attributes
      IFS='|' read -r -a REAL_ACC < <(grep "${REAL_FQUN}" /tmp/docker-mailserver/postfix-accounts.cf)

      if [[ -z ${REAL_ACC[1]} ]]
      then
        dms_panic__misconfigured 'postfix-accounts.cf' 'alias configuration'
      fi

      # test if user has a defined quota
      if [[ -f /tmp/docker-mailserver/dovecot-quotas.cf ]]
      then
        IFS=':' read -r -a USER_QUOTA < <(grep "${REAL_FQUN}:" -i /tmp/docker-mailserver/dovecot-quotas.cf)
        if [[ ${#USER_QUOTA[@]} -eq 2 ]]
        then
          REAL_ACC[2]="${REAL_ACC[2]:+${REAL_ACC[2]} }userdb_quota_rule=*:bytes=${USER_QUOTA[1]}"
        fi
      fi

      echo \
        "${ALIAS}:${REAL_ACC[1]}:5000:5000::/var/mail/${REAL_DOMAINNAME}/${REAL_USERNAME}::${REAL_ACC[2]:-}" \
        >> /etc/dovecot/userdb
    done < /tmp/docker-mailserver/postfix-virtual.cf
  fi
}
