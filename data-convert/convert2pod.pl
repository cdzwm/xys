use utf8;
use Modern::Perl;
use FindBin;
use Log::Log4perl qw(get_logger);
use Config::Tiny;
use Mojo::UserAgent;
use IO::Uncompress::Unzip qw(unzip $UnzipError) ;
use File::Find;
use Encode qw(decode);
use DBI;
use Data::Dump qw(dump);

# declare & init $sdir
my $sdir;
BEGIN{
	$sdir="$FindBin::Bin";
}

# use my lib paths
use lib "$sdir/lib";
use lib "$sdir/type-plugins";

# init log
Log::Log4perl->init_and_watch("$FindBin::Bin/log.conf",10);
my $log = Log::Log4perl->get_logger('Progress');

# read db config
my $conf=Config::Tiny->read("$FindBin::Bin/d.conf");
my ($db_server, $db_password, $db_port) = @{$conf->{db}}{qw(db_server db_password db_port)};

sub get_ua{
	my $ts = shift || 120;
	my $ua=Mojo::UserAgent->new->connect_timeout($ts)->request_timeout($ts)->inactivity_timeout($ts * 3);
	$ua;
};

# set timeout equal 300
my $ua=get_ua 300;

sub get_update_files{
	my @files;
	eval{
		find(sub{
			if( $_ ne '.' and $_ ne '..'){
				push @files, $File::Find::name;
			}
			
		}, "$sdir/data");
	};

	@files;
}

sub down_file{
	my $file_url=shift;
	my $file_data=eval{
		for(1..5){
			my $res=$ua->get($file_url)->result;
			if($res->code && $res->code == 200){
				return $res->body;
			}
			else{
				$log->error('Code: ', $res->code);
				$log->error('Error: ', $res->message);
				sleep 5;
			}
		}
	};
	
	if( $@ ){
		return;
	}

	$file_data;
}

my @types=&load_file_format_plugins;

sub parse_file{
	my $file_data=shift;
	my $text = decode('cp936', $file_data);
	$text =~ s/\r\n/\n/g;

	# try every format until someone can parse it
	for(@types){
		my $r=$_->new->recognize($text);
		if($r){
			return $r;
		}
	}

	$log->error('Unknown file format.');
	return;
}

sub load_file_format_plugins{
	my @formats;
	eval{
		find(sub{
			if( $_ ne '.' and $_ ne '..'){
				require $_;
				push @formats, $_ =~ /^(.*)\..*$/;
			}
			
		}, "$sdir/type-plugins");
	};

	if($@){
		$log->error("Load type plugin error: $@");
		return;
	}

	@formats;
}

my $dbh = eval{
	DBI->connect("dbi:mysql:database=xys_data;host=$db_server;port=$db_port;mysql_enable_utf8=1",
		'root', "$db_password", 
		{AutoCommit=>1, RaiseError=>1, PrintError=>1, 
		FetchHashKeyName=>'NAME_lc', dbi_connect_method=>'connect_cached'});
};

if($@){
	$log->debug("connect to db error: $@");
}

eval{
	$dbh->do('truncate table article');
	$dbh->do('truncate table issue');
};

if($@){
	$log->debug("clear tables error: $@");
}

sub write_issue{
	my $issue=shift;
	my $issue_id;
	eval{
		my $sth=$dbh->prepare('insert into issue(name, file_name) values(?, ?)');
		$sth->execute(@$issue{qw(issue file_name)});
		$issue_id=$dbh->last_insert_id(undef, undef, undef, undef);
	};
	if($@){
		$log->debug("write issue error: $@");
	}

	$issue_id;
}

sub convert_article{
	my $u=shift;
	
	my $issue_id=eval{
		return &write_issue({issue => $u->{issue}, file_name => $u->{file_name}});
	};
	
	if( length $issue_id > 5){
		say STDERR $issue_id;
	}

	if($@){
		$log->error("Write issue '$u->{issue}' error.");
	}

	for (@{ $u->{articles} }) {
		my $article=$_;
		eval{
			#date datetime, seqid int, title nvarchar(512))
			my $sth=$dbh->prepare('insert into article(`date`, seqid, title, content, issue_id) values(?, ?, ?, ?, ?)');
			$sth->execute(@$article{qw(date seqid title content)}, $issue_id);
		};
		if($@){
			$log->debug("write article error: $@");
		}
	}

	1;
}

sub convert_every_file{
	my @files=@_;
	for(@files){
		my $file=$_;
		open my $f, '<', $file;
		my $output='';

		# unzip
		unzip $f => \$output;
		if ( $UnzipError ) {
			$log->error("unzip error: $file");
			next;
		}

		#parse file
		my $u=parse_file($output);
		unless($u){
			$log->error("parse file error: $file");
			next;
		}

		$u->{file_name}=$file;

		&convert_article($u);

		say STDERR "$file";
	}
}

if( my @files=&get_update_files){
	&convert_every_file(  @files );
}
else{
	$log->debug('down index error');
}
