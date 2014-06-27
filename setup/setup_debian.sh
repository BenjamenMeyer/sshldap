#!/bin/bash

###########################
# Script Config Variables #
###########################

# TBD: Override these with command-line arguments

    # Files and Paths
    LDAP_BASE_DIR="/etc/ldap"
    LDAP_USER="openldap"
    LDAP_GROUP="openldap"

    # External Programs
    CHOWN=/bin/chown
    CHMOD=/bin/chmod
    GNU_CERTTOOL=/usr/bin/certtool
    LDAP_MODIFY=/usr/bin/ldapmodify
    MAKE_TEMP_FILE=/bin/mktemp
    RM=/bin/rm

######################
# Run Time Variables #
######################

    LDAP_DC=""
    LDAP_ADMIN=""
    LDAP_SERVER_ADDRESS=""

    TLS_CACERT=""
    TLS_SERVER_PRIVATE_KEY_FILE=""
    TLS_SERVER_CERT_FILE=""
    TLS_SELF_SIGNED="No"

    # Error Strings
    USER_MUST_BE_ROOT="You must be a root level user to perform this action"

#####################
# Utility Functions #
#####################

# Check if the user is a root-level user
# This can be achieved by using 'sudo'
function is_user_root()
    {
    for USER_GROUP in `groups`
    do
        if [ "${USER_GROUP}" == "root" ]; then
            return 1
        fi
    done

    return 0
    }

# Get the LDAP DC infromation - e.g example.com => dc=example,dc=com
function get_ldap_dc()
    {
    if [ -z "${LDAP_DC}" ]; then
        read -p "Please enter the LDAP DC: " LDAP_DC
    fi

    if [ -n "${LDAP_DC}" ]; then
        return 1
    else
        echo "Failed to get LDAP DC data."
        return 0
    fi
    }

# Get the Admin User Information - e.g cn=admin
function get_ldap_admin()
    {
    get_ldap_dc
    if [ $? -eq 0 ]; then
        return 0
    fi

    if [ -z "${LDAP_ADMIN}" ]; then
        read -p "Please enter the Admin User Name for ${LDAP_DC} (e.g cn=admin): " LDAP_ADMIN
    fi

    if [ -n "${LDAP_ADMIN}" ]; then
        return 1
    else
        echo "Failed to get LDAP Admin User"
        return 0
    fi
    }

# Tell user how to configure a portion of the LDAP Configuration to enable LDAPS how they want
function warn_user_config_update_ldaps()
    {
    echo
    echo "WARNING: Remote hosts will only be able to access the LDAP Server via LDAPS if"
    echo "   the LDAPS port is visible through the firewall."
    echo
    for ENTRY in `grep ldaps /etc/services`
    do
        echo "  ${ENTRY}"
    done
    echo
    echo "  If using the UFW Firewall Solution, then you can do the following to enable LDAPS:"
    echo
    echo "  $ sudo ufw allow ldaps"
    echo
    echo "  Note: You may need to modify /etc/ufw/applications.d/ufw-directoryserver to differentiate"
    echo "      between LDAP and LDAPS"
    echo
    }

# Update Distro Specific LDAP Configuration Data
function update_distro_server_configuration()
    {
    if [ -f /etc/debian_version ]; then

        local DEBIAN_LDAP_CONFIG_FILE="/etc/default/slapd"

        echo "Updating ${DEBIAN_LDAP_CONFIG_FILE} to:"
        echo "  Keep LDAPI on localhost"
        echo "  Keep IPC LDP"
        echo "  Add LDAPS for everything else"
        sed -i "s/SLAPD_SERVICES=\"ldap:\/\/\/ ldapi:\/\/\/\"/SLAPD_SERVICES=\"ldap:\/\/127.0.0.1:389\/ ldaps:\/\/\/ ldapi:\/\/\/\"/" "${DEBIAN_LDAP_CONFIG_FILE}"
        echo
    fi
    }

# Retrieve the LDAP Server Address from the user
function get_ldap_server_address()
    {
    local IFS_OLD=${IFS}
    local PS3_OLD=${PS3}

    PS3="Is the LDAP Server remote? "
    IFS='
'
    OPTIONS="Yes
No"
    select OPTION in ${OPTIONS}
    do
        case "${OPTION}" in
            "Yes")
                read -p "Please enter the server address: " LDAP_SERVER_ADDRESS
                local PS3_MAIN=${PS3}
                local TERMINATE="No"
                PS3="Is ${LDAP_SERVER_ADDRESS} correct? "
                select TERMINATE in ${OPTIONS}
                do
                    case "${OPTION}" in
                        "Yes")
                            break
                            ;;

                         "No")
                            break
                            ;;
                    esac
                done

                PS3=${PS3_MAIN}

                if [ "${TERMINATE}" == "Yes" ]; then
                    break
                fi
                ;;

            "No")
                LDAP_SERVER_ADDRESS="127.0.0.1"
                break
                ;;
        esac
    done

    echo "LDAP Server Address: ${LDAP_SERVER_ADDRESS}"

    PS3=${PS3_OLD}
    IFS=${IFS_OLD}

    if [ -n "${LDAP_SERVER_ADDRESS}" ]; then
        return 1
    else
        return 0
    fi
    }

# Get the TLS Certificate information
# Takes 1 parameter:
#   CLIENT_ONLY: true/false
#       If true, then only prompts for the CA Cert
#       If false, prompts for the CA Cert, Server Private Key, and Server Certificate
function get_tls_certs()
    {
    local CLIENT_ONLY=${1}

    if [ -z "${TLS_CACERT}" ]; then
        read -p "Please enter the full path to the CA's PEM file: " TLS_CACERT
    fi

    if [ ${CLIENT_ONLY} ]; then

        if [ -n "${TLS_CACERT}" ]; then
            return 1
        else
            echo "Failed to get Certificate Authority's Key"
            return 0
        fi

    else

        if [ -z "${TLS_SERVER_PRIVATE_KEY_FILE}" ]; then
            read -p "Please enter the Server's Private Key PEM file: " TLS_SERVER_PRIVATE_KEY_FILE
        fi

        if [ -z "${TLS_SERVER_CERT_FILE}" ]; then
            read -p "Please enter the Server's Signed Key PEM (CRT) file: " TLS_SERVER_CERT_FILE
        fi

        local IFS_OLD=${IFS}
        local PS3_OLD=${PS3}

        IFS='
    '
        OPTIONS="Yes
No"
        PS3="Are the certificates self-signed? "
        select TLS_SELF_SIGNED in ${OPTIONS}
        do
            case "${TLS_SELF_SIGNED}" in
                "Yes")
                    break
                    ;;
                "No")
                    break
                    ;;
            esac
        done

        PS3=${PS3_OLD}
        IFS=${OLD_IFS}

        if [ -n "${TLS_CACERT}" ]; then
            if [ -n "${TLS_SERVER_PRIVATE_KEY_FILE}" ]; then
                if [ -n "${TLS_SERVER_CERT_FILE}" ]; then
                    return 1
                else
                    echo "Failed to get Server's Signed Key"
                    return 0
                fi
            else
                echo "Failed to get Server's Private Key"
                return 0
            fi
        else
            echo "Failed to get Certificate Authority's Key"
            return 0
        fi

    fi
    }

# Generate GNU TLS Certs
function generate_tls_certs()
    {
    get_tls_certs false
    if [ $? -eq 1 ]; then
        local IFS_OLD=${IFS}
        local PS3_OLD=${PS3}

        PS3="Were the certificates issued by OpenSSL? "
        IFS='
'
        OPTIONS="Yes
No"
        select OPTION in ${OPTIONS}
        do
            case "${OPTION}" in
                "Yes")
                    local OPENSSL_PRIVATE_KEY="${TLS_SERVER_PRIVATE_KEY_FILE}"
                    local OPENSSL_CERTIFICATE="${TLS_SERVER_CERT_FILE}"

                    TLS_SERVER_PRIVATE_KEY_FILE="${LDAP_BASE_DIR}/ldap.gnutls.key"
                    TLS_SERVER_CERT_FILE="${LDAP_BASE_DIR}/ldap.gnutls.crt"

                    echo "OpenSSL Private Key: ${OPENSSL_PRIVATE_KEY}"
                    echo "OpenSSL Certificate: ${OPENSSL_CERTIFICATE}"
                    echo "Target GNUTLS Private Key: ${TLS_SERVER_PRIVATE_KEY_FILE}"
                    echo "Target GNUTLS Certificate: ${TLS_SERVER_CERT_FILE}"
                    ${GNU_CERTTOOL} --generate-privkey --outfile "${TLS_SERVER_PRIVATE_KEY_FILE}"
                    ${GNU_CERTTOOL} --generate-certificate --load-privkey "${TLS_SERVER_PRIVATE_KEY_FILE}" --outfile "${TLS_SERVER_CERT_FILE}" --load-ca-certificate "${OPENSSL_CERTIFICATE}" --load-ca-privkey "${OPENSSL_PRIVATE_KEY}"

                    ${CHOWN} ${LDAP_USER}:${LDAP_GROUP} "${TLS_SERVER_PRIVATE_KEY_FILE}"
                    ${CHMOD} 640 "${TLS_SERVER_PRIVATE_KEY_FILE}"
                    break
                    ;;
                "No")
                    break
                    ;;
            esac
        done

        PS3=${PS3_OLD}
        IFS=${IFS_OLD}

        return 1
    else
        echo "Failed to get existing certs from user"
        return 0
    fi
    }

# Add access control
function add_access_control()
    {
    is_user_root
    if [ $? -eq 1 ]; then
        get_ldap_dc
        if [ $? -eq 0 ]; then
            return 0
        fi

        get_ldap_admin
        if [ $? -eq 0 ]; then
            return 0
        fi

        ACCESS_LDIF=`${MAKE_TEMP_FILE}`

        echo "dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcAccess
olcAccess: {1}to attrs=loginShell,gecos
  by dn=\"${LDAP_ADMIN},${LDAP_DC}\" write
  by self write
  by * read
    " > "${ACCESS_LDIF}"

        ${LDAP_MODIFY} -Y EXTERNAL -H ldapi:/// -f "${ACCESS_LDIF}"
        local -i result=$?

        ${RM} "${ACCESS_LDIF}"

        return ${result}
    else
        echo ${USER_MUST_BE_ROOT}
        return 0
    fi
    }

# Add better indexing of the LDAP
function add_indexing()
    {
    is_user_root
    if [ $? -eq 1 ]; then

        INDEX_LDIF=`${MAKE_TEMP_FILE}`

        echo "dn: olcDatabase={1}hdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: cn pres,sub,eq
-
add: olcDbIndex
olcDbIndex: sn pres,sub,eq
-
add: olcDbIndex
olcDbIndex: uid pres,sub,eq
-
add: olcDbIndex
olcDbIndex: displayName pres,sub,eq
-
add: olcDbIndex
olcDbIndex: default sub
-
add: olcDbIndex
olcDbIndex: uidNumber eq
-
add: olcDbIndex
olcDbIndex: gidNumber eq
-
add: olcDbIndex
olcDbIndex: mail,givenName eq,subinitial
-
add: olcDbIndex
olcDbIndex: dc eq
" > "${INDEX_LDIF}"

        ${LDAP_MODIFY} -Y EXTERNAL -H ldapi:/// -f "${INDEX_LDIF}"
        local -i result=$?

        ${RM} "${INDEX_LDIF}"

        return ${result}


    else
        echo ${USER_MUST_BE_ROOT}
        return 0
    fi
    }

# Configure LDAP Server to use LDAPS for secure inter-system communications
function convert_to_ldaps_server()
    {
    is_user_root
    if [ $? -eq 1 ]; then
        generate_tls_certs
        if [ $? -eq 1 ]; then

            LDAPS_LDIF=`${MAKE_TEMP_FILE}`

            if [ "${TLS_SELF_SIGNED}" == "No" ]; then
                echo "dn: cn=config
add: olcTLSCACertificateFile
olcTLSCACertificateFile: ${TLS_CERT}
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${TLS_SERVER_PRIVATE_KEY_FILE}
-
add: olcTLSCertificateFile
olcTLSCertificateFile: ${TLS_SERVER_CERT_FILLE}
" > "${LDAPS_LDIF}"
            else
                echo "dn: cn=config
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${TLS_SERVER_PRIVATE_KEY_FILE}
-
add: olcTLSCertificateFile
olcTLSCertificateFile: ${TLS_SERVER_CERT_FILE}
-
add: olcTLSVerifyClient
olcTLSVerifyClient: never
" > "${LDAPS_LDIF}"
            fi

            ${LDAP_MODIFY} -Y EXTERNAL -H ldapi:/// -f "${LDAPS_LDIF}"
            local -i result=$?

            update_distro_server_configuration

            warn_user_config_update_ldaps

            ${RM} "${LDAPS_LDIF}"

            return ${result}

        fi
    else
        echo ${USER_MUST_BE_ROOT}
        return 0
    fi
    }

# Configure LDAP Client to use LDAPS for secure inter-system communications
function configure_ldap_client()
    {
    is_user_root
    if [ $? -eq 1 ]; then
        get_ldap_dc
        if [ $? -eq 1 ]; then

            get_tls_certs true

            if [ $? -eq 1 ]; then

                get_ldap_server_address

                if [ $? -eq 1 ]; then

                    cp "${LDAP_BASE_DIR}/ldap.conf" "${LDAP_BASE_DIR}/ldap.conf.backup"

                    sed -i "s/^TLS_CACERT/#OLD TLS_CACERT/" "${LDAP_BASE_DIR}/ldap.conf"
                    echo "BASE  ${LDAP_DC}" >> "${LDAP_BASE_DIR}/ldap.conf"
                    echo "URI   ldaps://${LDAP_SERVER_ADDRESS}/" >> "${LDAP_BASE_DIR}/ldap.conf"
                    echo "TLS_CACERT    ${TLS_CACERT}" >> "${LDAP_BASE_DIR}/ldap.conf"
                    return 1

                else

                    echo "Unable to get the required data for configuring the client"
                    return 0

                fi


            else

                echo "Unable to get the required data for configuring the client"
                return 0

            fi

        else

            echo "Unable to get the required data for configuring the client"
            return 0

        fi
    else
        echo ${USER_MUST_BE_ROOT}
        return 0
    fi
    }

# Configure LDAP Server with users, groups, LDAPS, etc.
function configure_ldap_server()
    {
    add_indexing
    if [ $? -eq 0 ]; then
        echo "Failed to add indexing"
        return 0
    fi

    add_access_control
    if [ $? -eq 0 ]; then
        echo "Failed to add access control"
        return 0
    fi

    convert_to_ldaps_server
    if [ $? -eq 0 ]; then
        echo "Failed to convert to LDAPS"
        return 0
    fi

    echo "Restarting OpenLDAP to move from the insecure LDAP to the secure LDAPS"
    /etc/init.d/slapd restart
    return $?
    }

function install_openldap_debian()
    {
    # OpenLDAP -> slapd
    # ldapmodify, etc -> ldap-utils
    # user/group add/remove helpers -> ldapscripts
    # TLS Cert support -> gnutls-bin
    apt-get install slapd ldap-utils ldapscripts gnutls-bin

    # apt-get install slapd only prompts for the administrative password for LDAP
    # There's more that must be configured which can be accessed by reconfiguring the package
    dpkg-reconfigure -plow slapd
    }

# Install OpenLDAP
function install_openldap()
    {
    # User must be root to use package management software
    is_user_root
    if [ $? -eq 1 ]; then

        local -i result=0

        # Distributions
        if [ -f /etc/debian_version ]; then
            echo "Detected Debian Distro..."

            install_openldap_debian
            local -i result=$?
        fi

        # Check if the distribution successfully installed the tools we require
        if [ ${result} -eq 1 ]; then
            configure_ldap_server
            return $?
        fi
    else
        echo ${USER_MUST_BE_ROOT}
        return 0
    fi
    }


function main()
    {
    PS3="Select option: "
    IFS='
'
    ACTIONS="Install OpenLDAP
Configure Client
Configure Server
Server: Convert to LDAPS
Exit"
    select ACTION in ${ACTIONS}
    do
        case "${ACTION}" in
            "Install OpenLDAP")
                install_openldap
                ;;

            "Configure Client")
                configure_ldap_client
                ;;

            "Configure Server")
                configure_ldap_server
                ;;

            "Server: Convert to LDAPS")
                convert_to_ldaps_server
                if [ $? -eq 1 ]; then
                    echo "Convertion complete."
                    echo "Please remember to restart the LDAP Server and update all LDAP users to ldaps:// from ldapi://"
                fi
                ;;

            "Exit")
                echo "Terminating"
                break
                ;;
        esac
    done
    }

main
