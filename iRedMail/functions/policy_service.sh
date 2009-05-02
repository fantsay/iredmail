#!/bin/bash

# Author:   Zhang Huangbin (michaelbibby <at> gmail.com).
# Date:     2008.04.07

# ---------------------------------------------
# pypolicyd-spf.
# ---------------------------------------------
pypolicyd_spf_config()
{
    ECHO_INFO "Install pypolicyd-spf for SPF."
    cd ${MISC_DIR}
    extract_pkg ${PYPOLICYD_SPF_TARBALL} && \
    cd pypolicyd-spf-${PYPOLICYD_SPF_VERSION} && \
    ECHO_INFO "Install pypolicyd-spf-${PYPOLICYD_SPF_VERSION}." && \
    python setup.py build >/dev/null && python setup.py install >/dev/null
    
    postconf -e spf-policyd_time_limit='3600'

    cat >> ${POSTFIX_FILE_MASTER_CF} <<EOF
policyd-spf  unix  -       n       n       -       -       spawn
  user=nobody argv=/usr/bin/policyd-spf
EOF

    cat >> ${TIP_FILE} <<EOF
SPF(pypolicyd-spf):
    - Configuration file:
        - /etc/python-policyd-spf/policyd-spf.conf
EOF

    echo 'export status_pypolicyd_spf_config="DONE"' >> ${STATUS_FILE}
}

# ---------------------------------------------
# Policyd.
# ---------------------------------------------
policyd_user()
{
    ECHO_INFO "==================== Policyd ===================="
    ECHO_INFO "Add user and group for policyd: ${POLICYD_USER_NAME}:${POLICYD_GROUP_NAME}."
    groupadd ${POLICYD_GROUP_NAME}
    useradd -d ${POLICYD_USER_HOME} -s /sbin/nologin -g ${POLICYD_GROUP_NAME} ${POLICYD_USER_NAME}

    echo 'export status_policyd_user="DONE"' >> ${STATUS_FILE}
}

policyd_config()
{
    ECHO_INFO "Initialize MySQL database of policyd."

    # Get SQL structure template file.
    tmp_sql="$(mktemp)"
    if [ X"${DISTRO}" == X"RHEL" ]; then
        export policyd_init_sql_file="$(eval ${LIST_FILES_IN_PKG} ${PKG_POLICYD} | grep '/DATABASE.mysql$')"
        echo '' > ${tmp_sql}    # Template file contains commands to create policyd database.
    elif [ X"${DISTRO}" == X"DEBIAN" -o X"${DISTRO}" == X"UBUNTU" ]; then
        policyd_init_sql_file_tmp="$(eval ${LIST_FILES_IN_PKG} ${PKG_POLICYD} | grep '/install/mysql$')"
        cp -f ${policyd_init_sql_file_tmp} /tmp/
        gunzip /tmp/$(basename ${policyd_init_sql_file_tmp})
        export policyd_init_sql_file="/tmp/$(basename ${policyd_init_sql_file_tmp})"
        cat > ${tmp_sql} <<EOF
CREATE DATABASE ${POLICYD_DB_NAME} DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci;
USE ${POLICYD_DB_NAME};
EOF
    else
        :
    fi

    cat >> ${tmp_sql} <<EOF
# Import SQL structure template.
SOURCE ${policyd_init_sql_file};

# Grant privileges.
GRANT SELECT,INSERT,UPDATE,DELETE ON ${POLICYD_DB_NAME}.* TO ${POLICYD_DB_USER}@localhost IDENTIFIED BY "${POLICYD_DB_PASSWD}";
FLUSH PRIVILEGES;

USE ${POLICYD_DB_NAME}
SOURCE ${SAMPLE_DIR}/policyd_blacklist_helo.sql;
EOF

    # Import whitelist/blacklist shipped in policyd and provided by iRedMail.
    if [ X"${DISTRO}" == X"RHEL" ]; then
        cat >> ${tmp_sql} <<EOF
SOURCE $(eval ${LIST_FILES_IN_PKG} ${PKG_POLICYD} | grep 'whitelist.sql');
SOURCE $(eval ${LIST_FILES_IN_PKG} ${PKG_POLICYD} | grep 'blacklist_helo.sql');
EOF

    elif [ X"${DISTRO}" == X"DEBIAN" -o X"${DISTRO}" == X"UBUNTU" ]; then
        # Create a temp directory.
        tmp_dir="/tmp/$(${RANDOM_STRING})" && mkdir -p ${tmp_dir}

        for i in $( eval ${LIST_FILES_IN_PKG} postfix-policyd | grep 'sql.gz$'); do
            cp $i ${tmp_dir}
            gunzip ${tmp_dir}/$(basename $i)

            cat >> ${tmp_sql} <<EOF
SOURCE /tmp/$(echo $i | awk -F'.gz' '{print $1}');
EOF
        done
    else
        :
    fi

    mysql -h${MYSQL_SERVER} -P${MYSQL_PORT} -u${MYSQL_ROOT_USER} -p"${MYSQL_ROOT_PASSWD}" <<EOF
$(cat ${tmp_sql})
EOF

    rm -rf ${tmp_sql} ${tmp_dir}
    [ X"${DISTRO}" == X"DEBIAN" -o X"${DISTRO}" == X"UBUNTU" ] && rm -f ${policyd_init_sql_file}
    unset tmp_sql tmp_dir

    # Configure policyd.
    ECHO_INFO "Configure policyd: ${POLICYD_CONF}."

    # We will use another policyd instance for recipient throttle
    # feature, it's used in 'smtpd_end_of_data_restrictions'.
    cp -f ${POLICYD_CONF} ${POLICYD_SENDER_THROTTLE_CONF}

    # Patch init script on RHEL/CentOS.
    [ X"${DISTRO}" == X"RHEL" ] && patch -p0 < ${PATCH_DIR}/policyd/policyd_init.patch >/dev/null

    # Set correct permission.
    chown ${POLICYD_USER_NAME}:${POLICYD_GROUP_NAME} ${POLICYD_CONF} ${POLICYD_SENDER_THROTTLE_CONF}
    chmod 0700 ${POLICYD_CONF} ${POLICYD_SENDER_THROTTLE_CONF}

    # Setup postfix for recipient throttle.
    cat >> ${POSTFIX_FILE_MAIN_CF} <<EOF
#
# Uncomment the following line to enable policyd sender throttle.
#
#smtpd_end_of_data_restrictions = check_policy_service inet:${POLICYD_SENDER_THROTTLE_BINDHOST}:${POLICYD_SENDER_THROTTLE_BINDPORT}
EOF

    # -------------------------------------------------------------
    # Policyd config for normal feature exclude recipient throttle.
    # -------------------------------------------------------------
    # ---- DATABASE CONFIG ----

    # Policyd doesn't work while mysql server is 'localhost', should be
    # changed to '127.0.0.1'.

    perl -pi -e 's#^(MYSQLHOST=)(.*)#${1}"$ENV{mysql_server}"#' ${POLICYD_CONF}
    perl -pi -e 's#^(MYSQLDBASE=)(.*)#${1}"$ENV{POLICYD_DB_NAME}"#' ${POLICYD_CONF}
    perl -pi -e 's#^(MYSQLUSER=)(.*)#${1}"$ENV{POLICYD_DB_USER}"#' ${POLICYD_CONF}
    perl -pi -e 's#^(MYSQLPASS=)(.*)#${1}"$ENV{POLICYD_DB_PASSWD}"#' ${POLICYD_CONF}
    perl -pi -e 's#^(FAILSAFE=)(.*)#${1}1#' ${POLICYD_CONF}

    # ---- DAEMON CONFIG ----
    perl -pi -e 's#^(DEBUG=)(.*)#${1}0#' ${POLICYD_CONF}
    perl -pi -e 's#^(DAEMON=)(.*)#${1}1#' ${POLICYD_CONF}
    perl -pi -e 's#^(BINDHOST=)(.*)#${1}"$ENV{POLICYD_BINDHOST}"#' ${POLICYD_CONF}
    perl -pi -e 's#^(BINDPORT=)(.*)#${1}"$ENV{POLICYD_BINDPORT}"#' ${POLICYD_CONF}

    # ---- CHROOT ----
    export policyd_user_id="$(id -u ${POLICYD_USER_NAME})"
    export policyd_group_id="$(id -g ${POLICYD_USER_NAME})"
    perl -pi -e 's#^(CHROOT=)(.*)#${1}$ENV{POLICYD_USER_HOME}#' ${POLICYD_CONF}
    perl -pi -e 's#^(UID=)(.*)#${1}$ENV{policyd_user_id}#' ${POLICYD_CONF}
    perl -pi -e 's#^(GID=)(.*)#${1}$ENV{policyd_group_id}#' ${POLICYD_CONF}

    # ---- WHITELISTING ----
    perl -pi -e 's#^(WHITELISTING=)(.*)#${1}1#' ${POLICYD_CONF}
    perl -pi -e 's#^(WHITELISTNULL=)(.*)#${1}0#' ${POLICYD_CONF}
    perl -pi -e 's#^(WHITELISTSENDER=)(.*)#${1}0#' ${POLICYD_CONF}
    perl -pi -e 's#^(AUTO_WHITE_LISTING=)(.*)#${1}1#' ${POLICYD_CONF}
    perl -pi -e 's#^(AUTO_WHITELIST_NUMBER=)(.*)#${1}10#' ${POLICYD_CONF}

    # ---- BLACKLISTING ----
    perl -pi -e 's#^(BLACKLISTING=)(.*)#${1}1#' ${POLICYD_CONF}
    #perl -pi -e 's#^(BLACKLIST_REJECTION=)(.*)#${1}"Blacklist, go away."#' ${POLICYD_CONF}
    #perl -pi -e 's#^(BLACKLIST_TEMP_REJECT=)(.*)#${1}0#' ${POLICYD_CONF}
    perl -pi -e 's#^(AUTO_BLACK_LISTING=)(.*)#${1}1#' ${POLICYD_CONF}
    perl -pi -e 's#^(AUTO_WHITELIST_NUMBER=)(.*)#${1}10#' ${POLICYD_CONF}

    # ---- BLACKLISTING HELO ----
    perl -pi -e 's#^(BLACKLIST_HELO=)(.*)#${1}0#' ${POLICYD_CONF}
    # ---- BLACKLIST SENDER ----
    perl -pi -e 's#^(BLACKLISTSENDER=)(.*)#${1}1#' ${POLICYD_CONF}

    # ---- HELO_CHECK ----
    perl -pi -e 's#^(HELO_CHECK=)(.*)#${1}1#' ${POLICYD_CONF}

    # ---- SPAMTRAP ----
    perl -pi -e 's#^(SPAMTRAPPING=)(.*)#${1}1#' ${POLICYD_CONF} 
    #perl -pi -e 's#^(SPAMTRAP_REJECTION=)(.*)#${1}"Spamtrap, go away."#' ${POLICYD_CONF} 

    # ---- GREYLISTING ----
    perl -pi -e 's#^(GREYLISTING=)(.*)#${1}1#' ${POLICYD_CONF} 
    #perl -pi -e 's#^(GREYLIST_REJECTION=)(.*)#${1}"Greylist, please try again later."#' ${POLICYD_CONF} 
    perl -pi -e 's#^(TRAINING_MODE=)(.*)#${1}0#' ${POLICYD_CONF} 
    perl -pi -e 's#^(TRIPLET_TIME=)(.*)#${1}5m#' ${POLICYD_CONF} 
    perl -pi -e 's#^(TRIPLET_AUTH_TIMEOUT=)(.*)#${1}7d#' ${POLICYD_CONF} 
    perl -pi -e 's#^(TRIPLET_UNAUTH_TIMEOUT=)(.*)#${1}2d#' ${POLICYD_CONF} 
    #perl -pi -e 's#^(OPTINOUT=)(.*)#${1}1#' ${POLICYD_CONF} 

    # ---- SENDER THROTTLE ----
    # Disable recipient throttle here, it should be used in postfix 
    # 'smtpd_end_of_data_restrictions'.
    perl -pi -e 's#^(SENDERTHROTTLE=)(.*)#${1}0#' ${POLICYD_CONF} 

    # ---- RECIPIENT THROTTLE ----
    perl -pi -e 's#^(RECIPIENTTHROTTLE=)(.*)#${1}1#' ${POLICYD_CONF} 

    # ---- RCPT ACL ----
    if [ X"${DISTRO}" == X"RHEL" ]; then
        perl -pi -e 's#^(RCPT_ACL=)(.*)#${1}1#' ${POLICYD_CONF} 
    else
        :
    fi

    # -------------------------------------------------------------
    # Policyd config for recipient throttle only.
    # -------------------------------------------------------------
    # ---- DATABASE CONFIG ----
    perl -pi -e 's#^(MYSQLHOST=)(.*)#${1}"$ENV{mysql_server}"#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(MYSQLDBASE=)(.*)#${1}"$ENV{POLICYD_SENDER_THROTTLE_DB_NAME}"#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(MYSQLUSER=)(.*)#${1}"$ENV{POLICYD_SENDER_THROTTLE_DB_USER}"#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(MYSQLPASS=)(.*)#${1}"$ENV{POLICYD_SENDER_THROTTLE_DB_PASSWD}"#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(FAILSAFE=)(.*)#${1}1#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- DAEMON CONFIG ----
    perl -pi -e 's#^(DEBUG=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(DAEMON=)(.*)#${1}1#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(BINDHOST=)(.*)#${1}"$ENV{POLICYD_SENDER_THROTTLE_BINDHOST}"#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(BINDPORT=)(.*)#${1}"$ENV{POLICYD_SENDER_THROTTLE_BINDPORT}"#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(PIDFILE=)(.*)#${1}"$ENV{POLICYD_SENDER_THROTTLE_PIDFILE}"#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- CHROOT ----
    export policyd_sender_throttle_user_id="$(id -u ${POLICYD_SENDER_THROTTLE_USER_NAME})"
    export policyd_sender_throttle_group_id="$(id -g ${POLICYD_SENDER_THROTTLE_USER_NAME})"
    perl -pi -e 's#^(CHROOT=)(.*)#${1}$ENV{POLICYD_SENDER_THROTTLE_USER_HOME}#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(UID=)(.*)#${1}$ENV{policyd_sender_throttle_user_id}#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(GID=)(.*)#${1}$ENV{policyd_sender_throttle_group_id}#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- RECIPIENT THROTTLE ----
    perl -pi -e 's#^(RECIPIENTTHROTTLE=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF} 

    # ------------------ DISABLE ALL OTHER FEATURES -----------------
    # ---- WHITELISTING ----
    perl -pi -e 's#^(WHITELISTING=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- BLACKLISTING ----
    perl -pi -e 's#^(BLACKLISTING=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- BLACKLISTING HELO ----
    perl -pi -e 's#^(BLACKLIST_HELO=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- BLACKLIST SENDER ----
    perl -pi -e 's#^(BLACKLISTSENDER=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- HELO_CHECK ----
    perl -pi -e 's#^(HELO_CHECK=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF}

    # ---- SPAMTRAP ----
    perl -pi -e 's#^(SPAMTRAPPING=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF} 

    # ---- GREYLISTING ----
    perl -pi -e 's#^(GREYLISTING=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF} 

    # ---- SENDER THROTTLE ----
    # We need only this feature in this policyd instance.
    perl -pi -e 's#^(SENDERTHROTTLE=)(.*)#${1}1#' ${POLICYD_SENDER_THROTTLE_CONF} 
    perl -pi -e 's#^(SENDER_THROTTLE_SASL=)(.*)#${1}1#' ${POLICYD_SENDER_THROTTLE_CONF} 
    perl -pi -e 's#^(SENDER_THROTTLE_HOST=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF} 
    perl -pi -e 's#^(QUOTA_EXCEEDED_TEMP_REJECT=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(SENDER_QUOTA_REJECTION=)(.*)#${1}"Limit has been reached."#' ${POLICYD_SENDER_THROTTLE_CONF}
    perl -pi -e 's#^(SENDERMSGSIZE=)(.*)#${1}$ENV{'MESSAGE_SIZE_LIMIT'}#' ${POLICYD_SENDER_THROTTLE_CONF} 
    perl -pi -e 's#^(SENDERMSGLIMIT=)(.*)#${1}60#' ${POLICYD_SENDER_THROTTLE_CONF} 

    # ---- RCPT ACL ----
    if [ X"${DISTRO}" == X"RHEL" ]; then
        perl -pi -e 's#^(RCPT_ACL=)(.*)#${1}0#' ${POLICYD_SENDER_THROTTLE_CONF} 
    else
        :
    fi

    # -----------------
    # Syslog Setting
    # -----------------
    if [ X"${POLICYD_SEPERATE_LOG}" == X"YES" ]; then
        perl -pi -e 's#^(SYSLOG_FACILITY=)(.*)#${1}$ENV{POLICYD_SYSLOG_FACILITY}#' ${POLICYD_CONF} 
        perl -pi -e 's#^(SYSLOG_FACILITY=)(.*)#${1}$ENV{POLICYD_SYSLOG_FACILITY}#' ${POLICYD_SENDER_THROTTLE_CONF} 
        echo -e "local1.*\t\t\t\t\t\t-${POLICYD_LOGFILE}" >> ${SYSLOG_CONF}
        cat > ${POLICYD_LOGROTATE_FILE} <<EOF
${CONF_MSG}
${AMAVISD_LOGFILE} {
    compress
    weekly
    rotate 10
    create 0600 amavis amavis
    missingok

    # Use bzip2 for compress.
    compresscmd $(which bzip2)
    uncompresscmd $(which bunzip2)
    compressoptions -9
    compressext .bz2 

    postrotate
        ${SYSLOG_POSTROTATE_CMD}
    endscript
}
EOF
    else
        :
    fi

    # Setup crontab.
    ECHO_INFO "Setting cron job for policyd user: ${POLICYD_USER_NAME}."
    cat > ${CRON_SPOOL_DIR}/${POLICYD_USER_NAME} <<EOF
${CONF_MSG}
1       */2       *       *       *       $(eval ${LIST_FILES_IN_PKG} ${PKG_POLICYD} | grep 'cleanup' | grep 'sbin') -c ${POLICYD_CONF}
1       */2       *       *       *       $(eval ${LIST_FILES_IN_PKG} ${PKG_POLICYD} | grep 'cleanup' | grep 'sbin') -c ${POLICYD_SENDER_THROTTLE_CONF}
EOF

    # Set cron file permission: root:root, 0600.
    chmod 0600 ${CRON_SPOOL_DIR}/${POLICYD_USER_NAME}

    # Add postfix alias.
    if [ ! -z ${MAIL_ALIAS_ROOT} ]; then
        echo "policyd: ${MAIL_ALIAS_ROOT}" >> ${POSTFIX_FILE_ALIASES}
        postalias hash:${POSTFIX_FILE_ALIASES}
    else
        :
    fi

    # Tips.
    cat >> ${TIP_FILE} <<EOF
Policyd:
    * Configuration files:
        - ${POLICYD_CONF}
    * RC script:
        - /etc/init.d/policyd
    * Misc:
        - /etc/cron.daily/policyd-cleanup
        - $(eval ${LIST_FILES_IN_PKG} ${PKG_POLICYD} | grep 'policyd.cron$')
        - crontab -l ${POLICYD_USER_NAME}
EOF

    if [ X"${POLICYD_SEPERATE_LOG}" == X"YES" ]; then
        cat >> ${TIP_FILE} <<EOF
    * Log file:
        - ${SYSLOG_CONF}
        - ${POLICYD_LOGFILE}

EOF
    else
        echo -e '\n' >> ${TIP_FILE}
    fi

    echo 'export status_policyd_config="DONE"' >> ${STATUS_FILE}
}

policy_service_config()
{
    # Enable pypolicyd-spf.
    [ X"${ENABLE_SPF}" == X"YES" -a X"${SPF_PROGRAM}" == X"pypolicyd-spf" ] && \
        check_status_before_run pypolicyd_spf_config

    check_status_before_run policyd_user
    check_status_before_run policyd_config

    echo 'export status_policy_service_config="DONE"' >> ${STATUS_FILE}
}
