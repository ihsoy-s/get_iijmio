#!/usr/bin/ruby -w
# -*- encoding: utf-8 -*-

=begin

= IIJmioのサイトから利用状況の情報を取得する

* データ利用量
  * 直近3日間の利用履歴
* クーポン残量
  * 総残量のみ

= configfileの構造

*config =>
  * logfile => ログ出力先ファイル名。何も指定していない場合STDOUT
  * loglevel => 'fatal', 'error', 'warn', 'info', or 'debug'. デフォルトはwarn。
  * smtp_host => SMTPサーバ
  * smtp_port => SMTPサーバのポート番号
  * smtp_fromaddress => メール送信時のFromに使用するアドレス
  * smtp_toaddress => メールの送信先アドレス
  * mail_subject => メールのSubject
  * id => サイトへログインする際に使用するmioID (平文)
  * password => サイトへログインする際に使用するパスワード (平文)

=end


if RUBY_VERSION < '1.9.0' then
  $KCODE='UTF8'
end

require 'yaml'
require 'logger'

require './parse_iijmio.rb'
require './mail_item.rb'


##### read config file #####

# 引数に指定がなかった場合は'config.yaml'を読み込む
if ARGV.size == 0 then
	configFile = 'config.yaml'
else
	configFile = ARGV.shift
end
begin
	config = YAML::load_file(configFile)
rescue
	puts 'could not load specified config file.'
	exit
end


##### logger setting #####

# if logfile is not specified, use stdout.
if (not config['config']['logfile']) or config['config']['logfile'] == '' then
	logger = Logger.new(STDOUT)
else
	logger = Logger.new(config['config']['logfile'], 5)
end
# default loglevel: warn
if (not config['config']['loglevel']) or config['config']['loglevel'] == '' then
	logger.level = Logger::WARN
else
	case config['config']['loglevel'].downcase
	when 'fatal'
		logger.level = Logger::FATAL
	when 'error'
		logger.level = Logger::ERROR
	when 'info'
		logger.level = Logger::INFO
	when 'debug'
		logger.level = Logger::DEBUG
	else
		logger.level = Logger::WARN
	end
end


##### check parameter #####

unless config['config']['smtp_host'] and config['config']['smtp_host'] != "" then
	logger.fatal "Insufficient Parameter (SMTP Host)."
	exit
end
unless config['config']['smtp_port'] and config['config']['smtp_port'] != "" then
	logger.fatal "Insufficient Parameter (SMTP Port)."
	exit
end
unless config['config']['smtp_fromaddress'] and config['config']['smtp_fromaddress'] != "" then
	logger.fatal "Insufficient Parameter (From)"
	exit
end
unless config['config']['smtp_toaddress'] and config['config']['smtp_toaddress'] != "" then
	logger.fatal "Insufficient Parameter (To)."
	exit
end
unless config['config']['id'] and config['config']['id'] != "" then
	logger.fatal "Insufficient Parameter (id)."
	exit
end
unless config['config']['password'] and config['config']['password'] != "" then
	logger.fatal "Insufficient Parameter (password)."
	exit
end


########## main ##########

# 基本的なメールヘッダ設定
mail_header = {
	'from' => config['config']['smtp_fromaddress'],
	'to' => config['config']['smtp_toaddress'],
	'subject' => config['config']['mail_subject'] + " (#{Time.now.strftime('%Y/%m/%d')})"}

# IIJmioへのアクセスパラメータ初期化
iijmio = IIJmioParser.new(config['config']['id'], config['config']['password'], logger)

# データ取得
result = iijmio.getData

# データ取得エラーの場合終了
exit unless result

# send e-mail (エラーでない場合のみ)
if iijmio.to_s != "" then
	mail_header['date'] = Time.now.strftime("%a, %d %b %Y %T %z")
	mail_body = {'plain' => iijmio.to_s, 'html' => iijmio.to_s}

	mail_item = MAIL_ITEM.new(config['config']['smtp_host'], config['config']['smtp_port'], mail_header, mail_body, logger)
	mail_item.send
end

