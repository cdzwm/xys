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

sub get_update_file_urls{
	my $index_page = 'http://127.0.0.1:3000/Index of _xys_packages.html';
	my $base_url='http://127.0.0.1:3000/';
	
	my $urls=eval{
		for(1..5){
			my $res = $ua->get($index_page)->result;
			if ($res->code && $res->code == 200) {
				my $aa=$res->dom->find('body > ul > li > a');
				return $res->dom->find('body > ul > li > a')->grep(sub{
					my $href=$_->attr('href');
					if($href =~ /\.zip$/){
						return $href;
					}
				})->map(sub{
					return $_->attr('href');
				});
				last;
			}
			else{
				sleep 5;
			}
		}
	};
	unless($@){
		return $urls;
	}
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

sub write_to_db{
	my $u=shift;
	
	my $issue_id=eval{
		return &write_issue({issue => $u->{issue}, file_name => $u->{file_name}});
	};

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

sub process_every_file{
	my @urls=@_;
	for(@urls){
		my $url=$_;
		my $output='';
		for(1..3){
			#download file
			my $file_data = &down_file($url);
			unless($file_data){
				$log->error("download file error: $url");
				sleep 5;
				next;
			}

			# unzip
			unzip \$file_data => \$output;
			if ( $UnzipError ) {
				$log->error("unzip error: $url");
				sleep 5;
				next;
			}
			else{
				last;
			}
		}

		#parse file
		my $u=parse_file($output);
		unless($u){
			$log->error("parse file error: $url");
			next;
		}

		$u->{file_name}=$url;

		say STDERR "Count of articles: ", scalar @{ $u->{articles} };
		&write_to_db($u);
	}
}

if( my $urls=&get_update_file_urls){
	&process_every_file(  @$urls );
}
else{
	$log->debug('down index error');
}
