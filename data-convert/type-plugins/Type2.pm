#!/usr/bin/perl
use utf8;
package Type2;
use Modern::Perl;
use Data::Dump qw(dump);
use Encode qw(decode encode);
use lib '../lib';
use Log::Log4perl qw(get_logger);
use Moose;
extends 'Type';
my $log = Log::Log4perl->get_logger('Type2');

sub reformat_para{
	my $para=shift;
	my @lines= split /\n+/, $para;
	chomp @lines;
	$para = join("\n", @lines);
	my @l=split /\n\s+/, $para;
	for (@l){
		s/\n+//g;
		s/^[\s\n]+//;
	}

	return join("\n", @l);
}

sub reformat_article{
	my $data=shift;
	my @p1 = split /\s*\n\s*\n\s*/, $data;

	my @paras;
	for(@p1){
		push @paras, reformat_para($_);
	}

	s/^\n// for @paras;
	
	my $re=qr/\s*[【[(（]?(?:\w*)[按评言][：:](?:.*)[】\])）]?\s*?$/s;
	my $title = ($paras[0] =~ $re) ? $paras[1] : $paras[0];
	return { title=>$title, content=>join("\n", map {$_} @paras)};
}

sub recognize{
	my (undef, $text) = @_;
	my $re=qr/^◇◇新语丝/m;

	# TODO: (ok)1. 有的文件没有 "新语丝新到资料(xxxx年xx月xx日)" 这个头。 需要从"(XYS20120326)"这种标记中提取, 或者从url中提取。(OK)
	#		(ok)2. 提取文章标题的算法需要优化。
	#			如: [按:
	#				[方舟子按：
	#				(方舟子按：  后边这个] 有可能有，也可能没有。
	#				[方舟子：
	#				[评]
	#					20170511标题解析不正确。
	#		3. 段落划分算法需要优化。
	#		4. 有些“网讯”的内容是空的。其他的章节也可能是空的。
	#		5. 文章排序。一个更新文件里的排序，目前是反的。
	#		6. 有的文件内容在 archives目录中。
	#		7. 提高下载的稳定性

	# check file format
	unless ($text =~ $re) {
		$log->debug('无法识别的文件格式');
		return;
	}

	# 第一种文件格式，用'◇◇新语丝(www.xys.org)(xys7.dxiong.com)(xys.ebookdiy.com)(xys2.dropin.org)◇◇'分隔文章
	my $sp1=quotemeta('◇◇新语丝(www.xys.org)') . '(?:.*?)' .  quotemeta('◇◇');
	my $re_sp1 =qr/(?:\n)?${sp1}\n/s;

	my @articles = split /$re_sp1/, $text;

	# remove last 2 articles
	splice @articles,-2;

	my $head=shift @articles;

	$head =~ s/^\s*|\s*$//;

	my $r={};
	eval{

		my $update_date;
		if( my (@ymd) = $head =~ /^\s*新语丝新到资料（(\d{4})年(\d{1,2})月(\d{1,2})日）\s*$/m ){
			$update_date = sprintf '%04d%02d%02d', @ymd;
		}

		$r->{issue}=$update_date;
		$r->{articles}=[];

		# parse each article
		my $seqid=0;

		for(reverse @articles){
			
			if($_ =~ /^\n*$/s){
				next;
			}

			my $article = &reformat_article($_);

			unless($update_date){
				#(XYS20050912)
				my ($article_update_date) = $_ =~ /^\(XYS(\d{4}\d{2}\d{2})\)$/mi;
				$article->{date} = $article_update_date;
			}
			else{
				$article->{date} = $update_date;
			}

			$article->{seqid}=$seqid++;
			push @{$r->{articles}}, $article;
		}
	};
	if($@){
		$log->error("$@");
	}
	$r;
}

1;
