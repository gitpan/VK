#!/usr/bin/perl

###################################################
##                                               ##
## VKontakte serverside manager                  ##
##                                               ##
## Marat Shaymardanov,   LeonMedia LLC, 2012     ##
## info@leonmedia.ru     http://leonmedia.ru     ##
##                                               ##
## http://vk.com/do.more                         ##
##                                               ##
###################################################

package VK;

require Exporter;

@ISA = qw(Exporter);
@EXPORT = qw();

use WWW::Mechanize::GZip;
use URI::Escape;

our $VERSION = '0.01';

sub new
{
	my ($class, $login, $pass, $wallurl, $security_code) = @_;
	my $self = {};

	bless $self, $class;

	my $mech = WWW::Mechanize::GZip->new(
		agent => 'Mozilla/5.0 (Windows; U; Windows NT 6.1; ru; rv:1.9.2.13) Gecko/20101203 Firefox/3.6.13',
		timeout => 30,
		onerror => sub {print "error\n"}
	);
	
	$mech->cookie_jar(HTTP::Cookies->new());
	$self->{mech} = $mech;

	if ($login){
		$self->login($login, $pass, $wallurl, $security_code);
	}

	return $self;
}

sub login
{
	my ($self, $login, $pass, $wallurl, $security_code) = @_;
	my $mech = $self->{mech};

	$self->{security_code} = $security_code;	
	$self->get("http://vk.com/login");

	# correct language
	$mech->content =~ m/hash: '([^']+)'/s;
	$mech->post("http://vk.com/al_index.php",{
		'act'     => 'change_lang',
		'lang_id' =>  0, # russian
		'hash'    => $1
	});

	$mech->form_number(1);
	$mech->field("email" => $login);
	$mech->field("pass" => $pass);

	my $r = $mech->submit();
	my $c = $r->content;
	my $wallid = undef;

	if ($c =~ m/parent\.onLoginDone\('([^']+)'\)/is){
		$self->{home} = $1;

		# wall hash
		if ($wallurl && ($wallurl ne $self->{home})){
			$self->get($wallurl);
			$c = $mech->content;

			# wall hash
			$c =~ m/"post_hash":"([^"]+)"/s;
			$self->{wall_hash} = $1;

			# wall oid
			$c =~ m/"wall_oid":([^,]+),/s;
			$wallid = $1;
		}
		
		# user hash
		$self->get($self->{home});
		$c = $mech->content;

		# get post hash
		$c =~ m/\"post_hash\":\"([^\"]+)"/s;
		$self->{hash} = $1;

		# get user id
		$c =~ m/id: (\d+)/s;
		$self->{id} = $1;
		
		$self->{wallurl} = $wallurl || $self->{home};
		$self->{wallid} = $wallid || $self->{id};

		return 1;
	}
	return 0;
}

sub createAlbum
{
	my ($self, $title, $desc, $permission, $commentable) = @_;
	my $mech = $self->{mech};

	$self->get('http://m.vk.com/photos?act=select_album');

	# get hash
 	if ($mech->content =~ m/photos\?act=new_album&hash=([\d\w]+)/){
		my $hash = $1;

		$mech->post(
			'http://m.vk.com/photos?act=new_album&hash='.$hash,{
				'title' => $title,
				'desc'  => $desc,
				'view'  => int($permission),
				'comm'  => int($commentable)
		});

		return ($mech->content =~ m/<div class="ok">Альбом успешно создан\.<\/div>/)?1:0;
	}

	return 0
}

sub get
{
	my $self = shift @_;
	my $mech = $self->{mech};
	from_security:
	my $r = $mech->get(@_);
	
	if ($mech->content =~ m/"loc":"\?act=security_check/s){
		$mech->content =~ m/{act: 'security_check', code: [^,]+, to: '([^']+)', al_page: '(\d+)', hash: '([^']+)'}/s;
		$mech->post("http://vk.com/login.php", {
			'act'  => 'security_check',		
			'code' => $self->{security_code},
			'to'   => $1,
			'hash' => $3,
			'al_page' => $2
		});
		goto from_security;
	}

	return $r;
}

sub addPhoto
{
	my ($self, $filePath, $albumName, $albumDesc, $permission, $commentable) = @_;
	my $mech = $self->{mech};

	$albumName = '#shared' if (!$albumName);

	do_again:
	$self->get("http://m.vk.com");

	my $link = $mech->find_link( text_regex => qr/Мои Фотографии/i );
	my $r = $self->get($link->url());

	$link = $mech->find_link( text_regex => qr/Добавить новые фотографии/i );
	$r = $self->get($link->url());
	my $c = $r->content;
	
	# check if album exists
	unless ($c =~ m/<div class="name">$albumName<\/div>/){
		$self->createAlbum($albumName, $albumDesc, $permission, $commentable);
		goto do_again;
	}

	if ($c =~ m/<a href=\"([^\"]+)\">\s+<div [^>]+>\s+<img [^>]+>\s+<\/div>\s+<div class=\"name\">$albumName<\/div>/){
		$r = $self->get($1);

		$mech->form_number(1);
		$mech->field("file1" => $filePath);
		$r = $mech->submit();

		$c = $r->content;	
		if ($c =~ m/<div class="warn">Загрузка завершена\.<\/div>/is){
			return $1 if ($c =~ m/\"\/photo(\d+_\d+)/is);
		}
	}

	return undef;
}

sub wallPost
{
	my ($self, %params) = @_;
	my $mech = $self->{mech};
	my $photoid = undef;
	
	if ($params{'photo'}){
		$photoid = $self->addPhoto(
			$params{'photo'},
			$params{'album'}, $params{'album_desc'},
			$params{'album_view'}, $params{'album_comments'}
		);
	}

	my $to_id = $params{'to_id'} || $self->{wallid};
	
	my $r = $self->get('http://vk.com'.(($to_id>0)?"/id$to_id":$self->{wallurl}));
	$mech->content =~ m/"post_hash":"([^"]+)"/s;
	
	my $post_hash = $1;

	my $h = {
			'act'           => 'post',
			'al'            => 1,
	 		'hash'          => $post_hash,
			'message'       => $params{'message'},
	  	'note_title'    => $params{'note_title'},
	  	'official'      => $params{'official'},
			'status_export' => '',
	  	'signed'        => $params{'signed'}?1:0,
			'to_id'         => $to_id,
			'type'          => ($to_id > 0)?'all':'own',
	};

	my $n = 0;

	if ($photoid){
		$n++;
		$h->{"attach$n\_type"} = 'photo';
		$h->{"attach$n"}       = $photoid;
	}

	if ($params{'link'}){
		$n++;	
		$h->{"attach$n\_type"} = 'share';
		$h->{"title"}          = $params{'link_title'},
		$h->{"description"}    = $params{'link_desc'},
		$h->{"url"}            = $params{'link'},
	}

	my $r = $mech->post("http://vk.com/al_wall.php", $h);
	my @codes = split(/<\!>/, $r->content);

	return ($codes[4] eq '0')?1:0;
}

=head1 NAME

VK - This module allows to manage VKontakte account: make posts with images and links, create albumbs and upload images.

=head1 SYNOPSIS

Simple usage:

use VK;

my $vk = VK->new('vkaccount@email.com', 'mypassword', undef, 1234);
print $vk->wallPost(
    message         => "Hello World!",
    link            => "http://code.google.com/p/vkontakte-non-api-manager",
    photo           => "sample.jpg"
)?'Success':'Failed';

=head1 DESCRIPTION

Detailed sample with comments:

use VK;

my $security_code = 1234; # last 4 digits of your phone registered to account

# login to post to our own wall
my $vk = VK->new('vkaccount@email.com', 'mypassword', undef, $security_code);

# next init sample is for group's wall posting
# my $vk = VK->new('vkaccount@email.com', 'mypassword', "/mygroupaddress", $security_code);

print $vk->wallPost(
	message         => "Hello World!", # post message
	#to_id           => 1234456, # userid/wallid where we are going to post, or void to post to own wall/group-wall

	link            => "http://code.google.com/p/vkontakte-non-api-manager",	# link
	link_title      => "This is the title of the link popup", # link popup description
	link_desc       => "This is the content of link popup", # link popup description

	signed          => '', # 1/0 - signs post if 
	note_title      => '',

	photo           => "sample.jpg",	
	album           => "This is the new album",
	album_desc      => "This is description of a new album",
	album_view      => 0, # 0-all, 1-friends, 2-friends&friends, 3-me
	album_comments  => 0,	# 0-all, 1-friends, 2-friends&friends, 3-me
)?'Succeeded':'Failed';

=head2 SUBROUTINES/METHODS

Extra functions:

# create album
$vk->createAlbum("Album name", "Album description");

# upload photo
$vk->addPhoto("photo.jpg", "Album name", "Album description", $view, $comments);

$view - means who can view album: 0-all, 1-friends, 2-friends&friends, 3-me
$comments - means who can view album: 0-all, 1-friends, 2-friends&friends, 3-me

# login to account
$vk->login('vkaccount@email.com', 'mypassword', $walluri, $security_code);

=head1 SEE ALSO

Module was made using WWW::Mechanize::GZip,
so if you are going to make any modifications next modules will be useful:

WWW::Mechanize
WWW::Mechanize::Gzip

=head1 AUTHOR

Marat Shaymardanov, E<lt>info@leonmedia.ruE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012 by Marat Shaymardanov, LeonMedia LLC 2012

This program is free software; you can redistribute it and/or modify it under the terms of either: the GNU General Public License as published by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1;