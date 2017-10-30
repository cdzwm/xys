database name:
	xys_data

tables:
	issue:
	+-----------+--------------+------+-----+---------+----------------+
	| Field     | Type         | Null | Key | Default | Extra          |
	+-----------+--------------+------+-----+---------+----------------+
	| id        | int(11)      | NO   | PRI | NULL    | auto_increment |
	| name      | varchar(128) | YES  |     | NULL    |                |
	| file_name | varchar(512) | YES  |     | NULL    |                |
	+-----------+--------------+------+-----+---------+----------------+

	article:
	+----------+--------------+------+-----+---------+----------------+
	| Field    | Type         | Null | Key | Default | Extra          |
	+----------+--------------+------+-----+---------+----------------+
	| id       | int(11)      | NO   | PRI | NULL    | auto_increment |
	| date     | datetime     | YES  |     | NULL    |                |
	| seqid    | int(11)      | YES  |     | NULL    |                |
	| title    | varchar(512) | YES  |     | NULL    |                |
	| content  | mediumtext   | YES  |     | NULL    |                |
	| issue_id | int(11)      | YES  | MUL | NULL    |                |
	+----------+--------------+------+-----+---------+----------------+
