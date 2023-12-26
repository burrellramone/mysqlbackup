# MySQL Backup

This is a backup script for MySQL databases.

The script will dump your databases using mysqldump, archive the databases in a single ZIP archive then email the archive to an address you specify.

The script uses a configuration file which you will set with your values. Copy conf.sample.ini to conf.ini and make your modifications there.

See below for the manual for mysqldump.

https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html

See below for manual for CURL.

https://curl.se/docs/manpage.html
