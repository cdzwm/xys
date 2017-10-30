use utf8;
use Modern::Perl;
use FindBin;
use Log::Log4perl qw(get_logger);
use Config::Tiny;
use Mojo::UserAgent;
use IO::Uncompress::Unzip qw(unzip $UnzipError) ;
use File::Find;
use Encode qw(decode);

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

sub get_ua{
	my $ts = shift || 120;
	my $proxy = shift || "socks://104.196.182.201:1080";
	my $ua=Mojo::UserAgent->new->connect_timeout($ts)->request_timeout($ts)->inactivity_timeout($ts * 3);
	$ua->proxy->http($proxy);
	$ua;
};

# set timeout equal 300
my $ua=get_ua 300;

sub get_update_file_urls{
	my $index_page = 'http://xys9.dxiong.com/xys/packages/';
	#my $index_page = 'http://xys.org/xys/packages/';
	my $base_url=$index_page;
	
	my $urls=eval{
		for(1..5){
			my $res = $ua->get($index_page)->result;
			if ($res->code && $res->code == 200) {
				return $res->dom->find('body > ul > li > a')->grep(sub{
					my $href=$_->attr('href');
					if($href =~ /^\w+\.zip$/){
						return $href;
					}
				})->map(sub{
					return $base_url . $_->attr('href');
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

sub process_every_file{
	my @urls=@_;
	for(@urls){
		my $url=$_;
		my $output='';
		my $file_data='';
		for(1..3){
			#download file
			$file_data = &down_file($url);
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

		# file name
		my ($file_name) = $url =~ /\/([^\/.]+)\.\w+$/;

		if( $file_data ){
			open my $f, '>', "data/$file_name.zip";
			binmode $f;
			print $f $file_data;
			close $f;
			say STDERR "download $url success.";
		}
		else{
			say STDERR "download $url failed.";
		}
		#parse file
#		my $u=parse_file($output);
#		unless($u){
#			$log->error("parse file error: $url");
#			next;
#		}
	}
}

# 下载文件索引，验证每一个文件
if( my $urls=&get_update_file_urls){
	&process_every_file(  @$urls );
}
else{
	$log->debug('down index error');
}
