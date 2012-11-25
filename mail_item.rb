#!/usr/bin/ruby -w
#
# = メール送信用ライブラリ
#

$KCODE='UTF8'

require 'kconv'
require 'net/smtp'
require 'logger'


##### MAIL ITEM #####

#
# = メール送信用クラス MAIL_ITEM
#
class MAIL_ITEM
	
	# メールヘッダ
	attr_reader :header
	
   #
   # ===初期化
   #
   # ==== 引数
   #
   # host:: メール送信用SMTPサーバ (String)
   # port:: SMTPサーバの接続先ポート (String)
   # header:: ヘッダ名をkey、値をvalueとして持つHash。 (Hash)
   # body:: body['plain'] => text/plainで送るtext、body['html'] => text/htmlで送るtext (Hash)
   # logger:: ログ出力先 (Logger)
   #
	def initialize(host, port, header, body, logger = nil)
		@smtp_host = host
		@smtp_port = port
		
		@header = header
		@body = body
		
		if logger.is_a?(Logger) then
			@logger = logger
		else
			@logger = nil
		end
		
		# パラメータ
		@encoding = true # bodyをBase64でエンコードするかどうか
		@html_mail = false
	end
	
	#
	# ===メールで送信するテキストを出力
	#
	# ==== 戻り値
	#
	# メールで送信されるヘッダ＆本文 (String)
	#
	def to_s
		# header作成
		maildata = putHeader
		
		# body作成
		if @html_mail then
			maildata += getMailBody_Html(@encoding)
		else
			bodycharset = Kconv.guess(@body['plain'])
			maildata += getMailBody('text/plain', @body['plain'], bodycharset, @encoding)
		end
		
		return maildata
	end
	
	# ===メール送信
	def send
		Net::SMTP.start(@smtp_host, @smtp_port) do |smtp|
			smtp.send_message(self.to_s, @header['from'], @header['to'])
			@logger.info "Transfered #{@header['subject']}, at #{@header['date']}" if @logger
		end
	end
	
	
	protected
	
	#
	# === HTMLメールの本文
	#
	# alternativeでtext/plainとtext/htmlを囲う形式のメール用テキストを作成する。
	# イメージは下記の通り。
	#   multipart/alternative
	#   ├text/plain
	#   └text/html
	#
	# ==== 引数
	#
	# plainencode:: text/plainをbase64エンコードするかどうか (True/False)
	#
	# ==== 戻り値
	#
	# メール用に整形したメール本文のテキスト(text/html)。 (String)
	#
	def getMailBody_Html(plainencode = false)
		boundary = getBoundary(10)
		charset = Kconv.guess(plain)
		
		# Content-Type = multipart/alternative を出力
		str = "Content-Type: multipart/alternative; boundary=\"#{boundary}\"\r\n\r\n"
		str += "--#{boundary}\r\n"
		
		# text/plainを作成
		str += getMailBody('text/plain', @body['plain'], charset, plainencode)
		str += "\r\n--#{boundary}\r\n"
		
		# text/htmlを作成
		str += getMailBody('text/html', @body['html'], charset, true)
		str += "\r\n--#{boundary}--\r\n\r\n"
		
		return str
		
	end
	
	#
	# === ContentTypeを含めたメール本文を作成
	#
	# ==== 引数
	#
	# type:: Content-Typeに記載する文字列。通常は 'text/plain' または 'text/html'。 (String)
	# str::  本文のtext (String)
	# bodycharset:: 文字コード (Kconvクラスの定数)
	# encoding:: 本文に対してBase64エンコードを行うかどうか (True/False)
	#
	# ==== 戻り値
	#
	# メール用に整形したメール本文のテキスト。
	#
	def getMailBody(type, str, bodycharset, encoding = false)
		
		maildata = getContentType(type, bodycharset, encoding)
		
		# body
		if encoding then
			maildata += toBase64(str)
		else
			maildata += str
		end
		
		@logger.debug "Mail #{type}: " + maildata if @logger
		
		return maildata
	end
	
	#
	# === Base64への変換
	#
	# 与えられたテキストをBase64でエンコードする。
	#
	# ==== 引数
	#
	# bin:: エンコードするテキスト (String)
	#
	# ==== 戻り値
	#
	# Base64でエンコードされたテキスト (String)
	#
	def toBase64(bin)
		[bin].pack("m")
	end
	
	#
	# === Base64な文字列のデコード
	#
	# 与えられたBase64のテキストをデコードする。
	#
	# ==== 引数
	#
	# str:: デコードするテキスト (String)
	#
	# ==== 戻り値
	#
	# デコードされたテキスト (String)
	#
	def decodeBase64(str)
		if /=\?[a-zA-Z0-9\-\_]+\?B\?([!->@-~]+)\?=/i =~ str then
			$1.unpack("m")[0]
		else
			str
		end
	end
	
	#
	# === Base64な文字列に変換する場合に必要なヘッダを付与
	#
	# Base64でエンコードされた文字列をメールで送信するために必要なヘッダを付与＆指定された文字列長でカット。
	#
	# ==== 引数
	#
	# str:: Base64でエンコードされたテキスト (String)
	#
	# ==== 戻り値
	#
	# 必要なヘッダを追加された、Base64でエンコードされたテキスト (String)
	#
	def prependEncodePrefix(str)
		# 空文字列なら何もしない
		if str == "" then
			return ""
		end
		
		# 文字コードを推定
		encoding = Kconv.guess(str)
		
		# base64の文字列は52文字ごとに区切る。(RFC2047で "An 'encoded-word' may not be more than 75 characters long" とあるため)
		esubject = Array.new
		case encoding
		when Kconv::SJIS
			@logger.debug "prependEncodePrefix: SJIS" if @logger
			toBase64(str).gsub(/\n/,"").scan(/.{1,52}/o) do |bstr|
				esubject.push '=?SHIFT_JIS?B?' + bstr + '?='
			end
		when Kconv::EUC
			@logger.debug "prependEncodePrefix: EUC" if @logger
			toBase64(str).gsub(/\n/,"").scan(/.{1,52}/o) do |bstr|
				esubject.push '=?EUC-JP?B?' + bstr + '?='
			end
		when Kconv::JIS
			@logger.debug "prependEncodePrefix: JIS" if @logger
			toBase64(str).gsub(/\n/,"").scan(/.{1,52}/o) do |bstr|
				esubject.push '=?ISO-2022-JP?B?' + bstr + '?='
			end
		else
			# 判別に失敗したものはUTF-8とみなす (US-ASCIIの場合もUTF-8であれば問題ないため)
			@logger.debug "prependEncodePrefix: UTF8" if @logger
			toBase64(str).gsub(/\n/,"").scan(/.{1,52}/o) do |bstr|
				esubject.push '=?UTF-8?B?' + bstr + '?='
			end
		end
		
		return esubject.join("\r\n ")
	end
	
	
	#
	# === Content-Type, Content-Transfer-Encodingヘッダを付出力
	#
	# Content-Typeヘッダ、およびContent-Transfer-Encodingヘッダを作成する。
	#
	# ==== 引数
	#
	# type ::     Content-Typeの値 (String)
	# charset ::  文字コード (Kconvクラスの定数)
	# encoding :: 本文をBase64エンコードするかどうか (True/False)
	#
	# ==== 戻り値
	#
	# Content-Typeヘッダ、およびContent-Transfer-Encodingヘッダのテキスト
	#
	def getContentType(type, charset, encoding = false)
		contenttype = "Content\-Type: #{type}; charset="
		
		case charset
		when Kconv::SJIS
			contenttype += "Shift_JIS\r\nContent-Transfer-Encoding: "
			if encoding then
				contenttype += "base64"
			else
				contenttype += "8bit"
			end
		when Kconv::EUC
			contenttype += "EUC-JP\r\nContent-Transfer-Encoding: "
			if encoding then
				contenttype += "base64"
			else
				contenttype += "8bit"
			end
		when Kconv::JIS
			contenttype += "ISO-2022-JP\r\nContent-Transfer-Encoding: "
			if encoding then
				contenttype += "base64"
			else
				contenttype += "7bit"
			end
		else
			# 不明なものはUTF-8とみなす (US-ASCIIの場合もUTF-8であれば問題ないため)
			contenttype += "utf-8\r\nContent-Transfer-Encoding: "
			if encoding then
				contenttype += "base64"
			else
				contenttype += "8bit"
			end
		end
		
		return contenttype + "\r\n\r\n"
	end
	
	#
	# === メールのpart区切りを作成する
	#
	# ==== 引数
	#
	# len:: part区切りの長さ (Integer)
	#
	# ==== 戻り値
	#
	# part区切りの文字列 (String)
	#
	def getBoundary(len = 10)
		src = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
		str = (Array.new(len) do
			src[rand(src.length)]
		end).join
		
		return str
	end
	
	#
	# === メールヘッダを出力
	#
	# メールヘッダを順に出力する。
	# @header のハッシュに含まれているもののうち下記のものを出力。
	#   - date
	#   - from
	#   - to
	#   - cc
	#   - bcc
	#   - subject
	#   - message-id
	#   - mime-version
	#   - reply-to
	#   - in-reply-to
	#
	# ==== 戻り値
	#
	# ヘッダ文字列 (String)
	#
	def putHeader
		str = ""
		str += 'Date: ' + @header['date'].to_s + "\r\n" if @header['date']
		str += 'From: ' + @header['from'] + "\r\n" if @header['from']
		str += 'To: ' + @header['to'] + "\r\n" if @header['to']
		str += 'Cc: ' + @header['cc'] + "\r\n" if @header['cc']
		str += 'Bcc: ' + @header['bcc'] + "\r\n" if @header['bcc']
		str += 'Subject: ' + prependEncodePrefix(@header['subject']) + "\r\n" if @header['subject']
		str += 'Message-ID: ' + @header['message-id'] + "\r\n" if @header['message-id']
		str += 'MIME-Version: ' + @header['mime-version'] + "\r\n" if @header['mime-version']
		str += 'Reply-To: ' + @header['reply-to'] + "\r\n" if @header['reply-to']
		str += 'In-Reply-To: ' + @header['in-reply-to'] + "\r\n" if @header['in-reply-to']
		
		return str
	end
	
end

