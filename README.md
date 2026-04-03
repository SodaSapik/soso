#!/bin/bash
set -e

# ============================================
# Configuration
# ============================================
DOMAIN="10.10.16.140"
ADMIN_EMAIL="admin@$DOMAIN"
DB_ROOT_PASS="RootDBPass123!"
MOODLE_DB="moodle_db"
MOODLE_USER="moodle_user"
MOODLE_PASS="MoodlePass123!"
MAIL_DB="roundcubemail"
MAIL_USER="roundcube_user"
MAIL_PASS="RoundcubePass123!"
MOODLE_DATA="/var/moodledata"
SITES_DIR="/var/www"

# ============================================
# 1. System update and package installation
# ============================================
echo "=== Updating system ==="
apt update && apt upgrade -y

echo "=== Installing Apache, PHP, MariaDB, Git, mail components ==="
apt install -y apache2 mariadb-server mariadb-client \
    php8.2 php8.2-cli php8.2-common php8.2-curl \
    php8.2-zip php8.2-gd php8.2-mysql php8.2-mbstring \
    php8.2-xml php8.2-intl php8.2-soap php8.2-apcu \
    postfix dovecot-core dovecot-imapd dovecot-pop3d \
    roundcube roundcube-mysql roundcube-plugins \
    git unzip wget certbot python3-certbot-apache \
    mailutils

# ============================================
# 2. MariaDB configuration
# ============================================
echo "=== Configuring MariaDB ==="
systemctl start mariadb
mysql_secure_installation <<EOF

y
$DB_ROOT_PASS
$DB_ROOT_PASS
y
y
y
y
EOF

echo "=== Creating databases and users ==="
mysql -u root -p$DB_ROOT_PASS <<EOF
CREATE DATABASE $MOODLE_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$MOODLE_USER'@'localhost' IDENTIFIED BY '$MOODLE_PASS';
GRANT ALL PRIVILEGES ON $MOODLE_DB.* TO '$MOODLE_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

mysql -u root -p$DB_ROOT_PASS <<EOF
CREATE DATABASE $MAIL_DB;
CREATE USER '$MAIL_USER'@'localhost' IDENTIFIED BY '$MAIL_PASS';
GRANT ALL PRIVILEGES ON $MAIL_DB.* TO '$MAIL_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# ============================================
# 3. Moodle installation and setup
# ============================================
echo "=== Downloading Moodle ==="
cd $SITES_DIR
git clone -b MOODLE_405_STABLE https://github.com/moodle/moodle.git moodle
mkdir -p $MOODLE_DATA
chown -R www-data:www-data $MOODLE_DATA
chmod 2770 $MOODLE_DATA

echo "=== Configuring Moodle ==="
cp $SITES_DIR/moodle/config-dist.php $SITES_DIR/moodle/config.php
sed -i "s|\$CFG->dbname    = 'moodle';|\$CFG->dbname    = '$MOODLE_DB';|" $SITES_DIR/moodle/config.php
sed -i "s|\$CFG->dbuser    = 'username';|\$CFG->dbuser    = '$MOODLE_USER';|" $SITES_DIR/moodle/config.php
sed -i "s|\$CFG->dbpass    = 'password';|\$CFG->dbpass    = '$MOODLE_PASS';|" $SITES_DIR/moodle/config.php
sed -i "s|\$CFG->wwwroot   = 'http://example.com';|\$CFG->wwwroot   = 'http://$DOMAIN/moodle';|" $SITES_DIR/moodle/config.php

cat >> $SITES_DIR/moodle/config.php <<EOF
\$CFG->dataroot = '$MOODLE_DATA';
\$CFG->directorypermissions = 0777;
EOF

chown -R www-data:www-data $SITES_DIR/moodle

# ============================================
# 4. Apache virtual host configuration
# ============================================
echo "=== Configuring Apache virtual host ==="
cat > /etc/apache2/sites-available/moodle.conf <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    DocumentRoot $SITES_DIR/moodle
    
    <Directory $SITES_DIR/moodle>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/moodle_error.log
    CustomLog \${APACHE_LOG_DIR}/moodle_access.log combined
</VirtualHost>
EOF

a2dissite 000-default.conf
a2ensite moodle.conf
a2enmod rewrite
systemctl restart apache2

# ============================================
# 5. Postfix configuration
# ============================================
echo "=== Configuring Postfix ==="
debconf-set-selections <<< "postfix postfix/mailname string $DOMAIN"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
dpkg-reconfigure -f noninteractive postfix

systemctl restart postfix

# ============================================
# 6. Dovecot configuration
# ============================================
echo "=== Configuring Dovecot ==="
sed -i 's/^#protocols = .*/protocols = imap pop3 lmtp/' /etc/dovecot/dovecot.conf
systemctl restart dovecot

# ============================================
# 7. Roundcube configuration
# ============================================
echo "=== Configuring Roundcube ==="
cat > /etc/roundcube/debian-db.php <<EOF
<?php
\$dbuser = '$MAIL_USER';
\$dbpass = '$MAIL_PASS';
\$basepath = '';
\$dbname = '$MAIL_DB';
\$dbserver = 'localhost';
\$dbport = '';
\$dbtype = 'mysql';
?>
EOF

mysql -u root -p$DB_ROOT_PASS $MAIL_DB < /usr/share/roundcube/SQL/mysql.initial.sql

cat > /etc/roundcube/config.inc.php <<EOF
<?php
\$config['db_dsnw'] = 'mysql://$MAIL_USER:$MAIL_PASS@localhost/$MAIL_DB';
\$config['default_host'] = 'localhost';
\$config['smtp_server'] = 'localhost';
\$config['smtp_port'] = 25;
\$config['imap_host'] = 'localhost';
\$config['imap_port'] = 143;
\$config['support_url'] = '';
\$config['product_name'] = 'Webmail';
\$config['des_key'] = '$(openssl rand -base64 24)';
\$config['plugins'] = ['archive', 'zipdownload'];
?>
EOF

ln -sf /etc/roundcube/config.inc.php /var/lib/roundcube/config/config.inc.php

cat > /etc/apache2/conf-available/roundcube.conf <<EOF
Alias /webmail /var/lib/roundcube
<Directory /var/lib/roundcube>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF

a2enconf roundcube
systemctl reload apache2

# ============================================
# 8. Create test mail user
# ============================================
echo "=== Creating test mail user ==="
useradd -m -s /bin/bash testuser
echo "testuser:TestPass123!" | chpasswd

# ============================================
# 9. Final setup and permissions
# ============================================
echo "=== Finalizing Moodle installation ==="
chown -R www-data:www-data $SITES_DIR/moodle
chmod -R 755 $SITES_DIR/moodle
chown -R www-data:www-data $MOODLE_DATA

# ============================================
# 10. Completion information
# ============================================
echo "========================================="
echo "Installation completed!"
echo "========================================="
echo "Moodle: http://$DOMAIN/moodle"
echo "Webmail: http://$DOMAIN/webmail"
echo ""
echo "Database credentials:"
echo "  Moodle DB: $MOODLE_DB / $MOODLE_USER / $MOODLE_PASS"
echo "  Roundcube DB: $MAIL_DB / $MAIL_USER / $MAIL_PASS"
echo "  MariaDB root: root / $DB_ROOT_PASS"
echo ""
echo "Test mail user: testuser / TestPass123!"
echo ""
echo "Complete Moodle setup via web installer first!"
echo "========================================="
