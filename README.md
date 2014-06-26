sshldap
=======

sshldap is a small project for configuring LDAP Public Key Authentication in SSH servers.

Licensing
---------
All scripts are licensed under the Apache License to the degree applicable.

Contributing
------------
Contributions are welcome. Please fork the repository and submit a pull request.

Acceptable tools will be written as either Bash Shell scripts or Python Scripts.

What this is
------------
- Documenation on how to setup SSH to use LDAP to find Public Keys
- Tools to enable OpenSSH and OpenLDAP to work together

What this is not
----------------
- any actual implementation of SSH or LDAP.

Goals
-----
- Document how to appropriately setup the LDAP Server
- Documentation how to appropriately setup the SSH Server
- Provide any tools required to make it easy, if possible
- Enable systems to authenticate via a centralized source
- Enable SSH to be locked down to only Public Key authentication via that same centralized source
- Works in both Cloud and non-Cloud instances
- Be relatively easy to do

