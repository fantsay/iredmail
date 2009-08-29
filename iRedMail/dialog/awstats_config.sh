#!/usr/bin/env bash

# Author:   Zhang Huangbin (michaelbibby <at> gmail.com)

#---------------------------------------------------------------------
# This file is part of iRedMail, which is an open source mail server
# solution for Red Hat(R) Enterprise Linux, CentOS, Debian and Ubuntu.
#
# iRedMail is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# iRedMail is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with iRedMail.  If not, see <http://www.gnu.org/licenses/>.
#---------------------------------------------------------------------

# --------------------------------------------------
# -------------------- Awstats ---------------------
# --------------------------------------------------

. ${CONF_DIR}/awstats

if [ X"${BACKEND}" == X"OpenLDAP" -o X"${BACKEND}" == X"MySQL" ]; then
    :
else
    # Set username for awstats access.
    while : ; do
        ${DIALOG} --backtitle "${DIALOG_BACKTITLE}" \
        --title "Specify \Zb\Z2username\Zn for access awstats from web browser" \
        --inputbox "\
Please specify \Zb\Z2username\Zn for access awstats from web browser.

Example:

    * michaelbibby

" 20 76 2>/tmp/awstats_username

        AWSTATS_USERNAME="$(cat /tmp/awstats_username)"
        [ X"${AWSTATS_USERNAME}" != X"" ] && break
    done

    echo "export AWSTATS_USERNAME='${AWSTATS_USERNAME}'" >>${CONFIG_FILE}
    rm -f /tmp/awstats_username

    # Set password for awstats user.
    while : ; do
        ${DIALOG} --backtitle "${DIALOG_BACKTITLE}" \
        --title "\Zb\Z2Password\Zn for awstats user: ${AWSTATS_USERNAME}" \
        --passwordbox "\
Please specify \Zb\Z2password\Zn for awstats user: ${AWSTATS_USERNAME}

Warning:

    * \Zb\Z1EMPTY password is *NOT* permitted.\Zn

" 20 76 2>/tmp/awstats_passwd

        AWSTATS_PASSWD="$(cat /tmp/awstats_passwd)"
        [ X"${AWSTATS_PASSWD}" != X"" ] && break
    done

    echo "export AWSTATS_PASSWD='${AWSTATS_PASSWD}'" >>${CONFIG_FILE}
    rm -f /tmp/awstats_passwd
fi
