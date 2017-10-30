use utf8;
use Modern::Perl;
use Log::Log4perl qw(get_logger);
use Encode qw(decode encode);
use IO::Uncompress::Unzip qw(unzip $UnzipError) ;
use Mojo::UserAgent;
use DBI;
use Config::Tiny;
use File::Find;
use FindBin;

use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/type-plugins";

# init log
Log::Log4perl->init_and_watch("$FindBin::Bin/log.conf",10);
my $log = Log::Log4perl->get_logger('Progress');

# read db config
my $conf=Config::Tiny->read("$FindBin::Bin/d.conf");
my ($db_server, $db_password, $db_port) = @{$conf->{db}}{qw(db_server db_password db_port)};

my $ua=Mojo::UserAgent->new;
$ua->transactor->name('User-Agent:Mozilla/5.0 (Windows NT 6.1; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/61.0.3163.91 Safari/537.36');
my $proxy="socks://175.138.65.244:1080";
#$ua->proxy->https($proxy);

sub load_file_format_plugins{
	my @formats;
	find(sub{
		if( $_ ne '.' and $_ ne '..'){
			require $_;
			push @formats, $_ =~ /^(.*)\..*$/;
		}
		
	}, "$FindBin::Bin/type-plugins");

	@formats;
}

# get update urls
sub get_update_file_urls{
	my $url='https://groups.yahoo.com/api/v1/groups/xys/messages';
	my $messages;
	for(1..5){
		#TODO: Auto set proxys that can access website 'https://groups.yahoo.com'
		my $res=$ua->get($url)->res;
		$messages=$res->json->{ygData}{messages}, last if $res->code && $res->code == 200;
	}

	my @urls;
	for ( @$messages ){
		
		if($_->{hasAttachments} && $_->{attachments}){
			if( defined ( my $type = $_->{attachments}[0]{fileType}) ){
				push @urls, {type => $type, link=>$_->{attachments}[0]{link}};
			}
			else{
				$log->debug("Can't find fileType. Subject: ", $_->{subject});
			}
		}
		else{
			$log->debug('No attachement(s) found. Subject: ', $_->{subject});
		}
		
	}

	@urls;
}

sub get_update_file{
	my $update_file_url=shift;
	for(1..3){
		my $res=$ua->get($update_file_url)->result;
		if($res->code && $res->code == 200){
			return $res->body;
		}
		else{
			$log->error('Code: ', $res->code);
			$log->error('Error: ', $res->message);
		}
	}
}

# 识别文件格式，并把文件拆分成基本组成部分
sub parse_update_file{
	my $file_data=shift;
	my $text = decode('cp936', $file_data);

	# try formats
	my @formats = &load_file_format_plugins;
	for(@formats){
		my $r=$_->new->recognize($text);
		return $r if $r;
	}

	$log->error('Unknown file format.');
	return;
}

my $dbh = eval{
	DBI->connect("dbi:mysql:database=xys_data;host=$db_server;port=$db_port;mysql_enable_utf8=1",
		'root', "$db_password", 
		{AutoCommit=>1, RaiseError=>1, PrintError=>1, 
		FetchHashKeyName=>'NAME_lc', dbi_connect_method=>'connect_cached'});
};

sub decode_file{
	my $update_file=$_;
	# attachement type: application/zip text/plain
	my $link=$_->{$_->{type}}{link};
	my $input=get_update_file ($link);

	my $output;
	my $file_type=$update_file->{type};
	if( $file_type eq 'zip'){
		my $status = unzip \$input => \$output;
	}
	elsif($file_type eq 'txt'){
		$output=$input;
	}
	else{
		$log->error('Unknown file type: ', $update_file->{link});
	}

	# 将 \r\n 转换为 \n
	$output =~ s/\r\n/\n/g;
	$output;
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

sub check_urls{
	my @urls=@_;

	my %uf;
	for(@urls){
		my ($filename, $type) = $_->{link} =~ /\/([^\/.]+)\.(\w+)$/;
		$uf{$filename}{$type}=$_;

		$uf{$filename}{issue} = $filename;
		$uf{$filename}{file} = "$filename.$type";

		if( defined($uf{$filename}) ){
			push @{$uf{$filename}{type}}, $type;
		}
		else{
			$uf{$filename}{type} = [$type];
		}
	}

	my @files;
	for(sort keys %uf){
		my $type = (reverse sort @{$uf{$_}{type}})[0];
		$uf{$_}{type}=$type;
		push @files, $uf{$_};
	}

	@files;
}

my @urls =&get_update_file_urls(@ARGV);

my @valid_urls = check_urls(@urls);
for( @valid_urls ){
	my $link=$_->{$_->{type}}{link};
	if( $link =~ /\/([^\/.]+)\.\w+$/ ){
		my $issue = $1;

		my ($name)=$dbh->selectrow_array('select name from issue where substr(name, 3) =?', {}, $issue);
		
		if( defined($name) ){
			$log->debug("$name already update.");
			next;
		}
	}

	my $output = decode_file $_;
	my $u=&parse_update_file($output);
	$u->{file_name}=$link;
	
	say STDERR "Count of articles: ", scalar @{ $u->{articles} };
	&write_to_db($u);
}
