#!/usr/bin/ruby -w
# -*- encoding: utf-8 -*-

#
# = IIJmioパーサ
#

if RUBY_VERSION < '1.9.0' then
  $KCODE='UTF8'
end

require 'kconv'
require 'open-uri'
require 'uri'
require 'logger'

#require 'rubygems'
require 'nokogiri'
require 'mechanize'

#
# = IIJmioパーサクラス
#
# == 処理に使う諸々
# 
# * ログイン画面： https://www.iijmio.jp/auth/login.jsp
# * 入力フォーム: <form method="POST" action="/j_security_check">
# * mioID: <input type="text" name="j_username" maxlength="10" value="" style="width:100px">
# * mioパスワード: <input type="password" name="j_password" maxlength="8" style="width:100px">
# * データ利用量: https://www.iijmio.jp/service/setup/hdd/viewdata/
# * クーポン残量: https://www.iijmio.jp/service/setup/hdd/couponstatus/
# * ログアウト: https://www.iijmio.jp/auth/logout.jsp
#
class IIJmioParser
	
	#
	# === 初期化
	#
	# 下記の検索パラメータを設定する。
	# * mioID
	# * mioパスワード
	# * 各種URL
	#
	# ==== 引数
	#
	# userid :: mioID (String)
	# userpass :: mioパスワード (String)
	# logger :: log出力先 (Logger)
	#
	def initialize(userid, userpass, logger = nil)
		@user_id = userid
		@user_pass = userpass
		
		# 結果格納用変数の初期化
		@history = nil
		@rest = nil
		
		# Mechanize agent
		@agent = Mechanize.new
		
		if logger.is_a?( Logger ) then
			@agent.log = logger
		else
			# log出力先のデフォルト値はSTDOUT出力 / LogLevel = WARN
			@agent.log = Logger.new( STDOUT )
			@agent.log.level = Logger::WARN
		end
	end
	
	#
	# === ログイン処理実行
	#
	# ログインする。
	#
	# ==== 戻り値
	#
	# _true_ :: ログイン成功
	# _false_ :: ログインエラー
	#
	def login
		
		uri_login = 'https://www.iijmio.jp/auth/login.jsp'
		
		# ログインフォーム情報
		login_form_action = '/j_security_check'
		login_form_id = 'j_username'
		login_form_pass = 'j_password'
		
		# login
		begin
			@agent.get( uri_login )
			@agent.log.info "Login Page title: " + @agent.page.title
			@agent.page.form_with( :action => login_form_action ) do |form|
				form.field_with( :name => login_form_id ).value = @user_id
				form.field_with( :name => login_form_pass ).value = @user_pass
				form.click_button
			end
		rescue
			@agent.log.error $!
			return false
		end
		
		return true
	end
	
	#
	# === ログアウト処理実行
	#
	# ログアウトする。
	#
	def logout
		uri_logout = 'https://www.iijmio.jp/auth/logout.jsp'
		
		@agent.get( uri_logout )
		@agent.log.info "Logout Page title: " + @agent.page.title
	end
	
	#
	# === HTMLファイル取得＆解析
	#
	# HTMLを取得して、中身を解析する。
	#
	# ==== 戻り値
	#
	# _nil_ :: 取得エラー
	# _true_ :: 取得成功
	# _false_ :: 取得データがおかしい (未実装)
	#
	def getData
		
		# login
		login()
		
		# データ取得
		begin
			
			# データ利用量のページ取得
			@history = getHistoryData()
			
			# [ { number => 電話番号, data => [ { date => 日付, lte_data => データ量, restricted_data => データ量}, {}, {}, {} ] }, ... ]
			@history.each do |data_hash|
				data_hash["data"].each do |history_data|
					@agent.log.info "#{history_data["date"].strftime('%Y/%m/%d')} (#{data_hash["number"]}) : #{history_data["lte_data"]}MB"
				end
			end
			
			# クーポン残量のページ
			@rest = getCouponData()
			@agent.log.info "クーポン残量(総容量)： #{@rest[0]}MB"
		
		rescue
			@agent.log.error $!
		ensure
			# エラー発生時でもログアウトだけは行う
			logout()
		end
		
		true
	end
	
	#
	# === 文字出力
	#
	# 取得した内容を、テキストに整形して出力する
	#
	# ==== 戻り値
	#
	# 整形されたテキスト (String)
	#
	def to_s
		
		str = ""
		
		if @history then
			# ヘッダ
			str += "\n●データ利用量履歴\n"
			# データの中身
			@history.each do |data_hash|
				str += "\n○#{data_hash["number"]}\n"
				data_hash["data"].each do |history_data|
					str += "\t#{history_data["date"].strftime('%Y/%m/%d')} : #{history_data["lte_data"]}MB\n"
				end
			end
		end
		
		if @rest then
			str += "\n●クーポン残量(総容量)： #{@rest[0]}MB\n"
			str += "\t○クーポン残量(今月分)： #{@rest[1]}MB\n"
			str += "\t○クーポン残量(先月分)： #{@rest[2]}MB\n"
		end
		
		return str
	end
	
	protected
	
	# 
	# === データ利用量取得
	#
	# 直近3日間のデータ利用量を取得する。
	# データ利用量の値は、「LTE/3G合計パケット量」と「128k合計パケット量」の合算値。
	#
	# ==== 引数
	#
	# なし
	#
	# ==== 戻り値
	#
	# Hash :: 電話番号、日付、データ量が格納されたHash。
	# _false_ :: 取得失敗した場合
	#
	def getHistoryData
		
		# 各種URL
		uri_data = 'https://www.iijmio.jp/service/setup/hdd/viewdata/'
		
		# データ利用量取得用XPath
		history_xpath = '//table[@class="base2"]/tr'
		history_number_xpath = '//table[@class="base2"]/form'
		
		# 一時変数
		history_array = Array.new	# [ { number => 電話番号, data => [ { date => 日付, lte_data => データ量, restricted_data => データ量}, {}, {}, {} ] }, ... ]
		history_array_idx = 0
		
		# 取得実行
		@agent.get( uri_data )
		@agent.log.info "Hitsory page title: " + @agent.page.title
		#@agent.log.debug @agent.page.body.toutf8
		
		# 電話番号を取得開始
		contents_number = @agent.page.search( history_number_xpath )
		
		# Xpathの解析に失敗した場合は、falseを返す
		unless contents_number
			@agent.log.warn "Parse error at tel-number"
			return false
		end
		
		contents_number.each do |node|
			number_data = node.xpath( './tr/td' )
			@agent.log.debug "Tel-number: #{number_data}"
			break unless number_data
			
			history = Hash.new			
			history = { "number" => /([\d\-]+)/.match( number_data.inner_text ).to_a[1], "data" => Array.new }
			
			history_array.push history
			
		end
		
		# 日付ごとのデータを取得開始
		contents = @agent.page.search( history_xpath )
		
		# Xpathの解析に失敗した場合は、falseを返す
		unless contents
			@agent.log.warn "Parse error at history data"
			return false
		end

		# 最初の2要素はヘッダなのでスキップ
		contents.drop(2).each_with_index do |node, idx|
			
			contents_data = node.xpath( './td' )
			@agent.log.debug "History-data: #{contents_data}"
			break unless contents_data
			
			history_data = Hash.new		# { number, date, lte_data, restricted_data }
			
			# tdの中身は、日付、LTE/3G合計パケット量、200k合計パケット量 の順番
			history_data["date"] = parseDate( contents_data[0].inner_text )
			history_data["lte_data"] = contents_data[1].inner_text.to_i
			history_data["restricted_data"] = contents_data[2].inner_text.to_i
			
			#@agent.log.debug "Hitsory data: date=#{history_data["date"]}, lte_data=#{history_data["lte_data"]}, restricted_data=#{history_data["restricted_data"]}".toutf8
			
			# 電話番号と関連付け
			history_array[ history_array_idx ][ "data" ].push history_data
			
			# 追加先の電話番号更新
			if history_array[ history_array_idx ][ "data" ].length >= 4 then
				history_array_idx += 1
			end
		end
		
		return history_array
	end
	
	# 
	# === クーポン残量取得
	#
	# ==== 引数
	#
	# なし
	#
	# ==== 戻り値
	#
	# 正の数 :: 総残量
	# 負の数 :: データ取得エラー
	#
	def getCouponData
		
		# 各種URL
		uri_coupon = 'https://www.iijmio.jp/service/setup/hdd/couponstatus/'
		
		# クーポン残量取得用XPath
		coupon_total_xpath = '//table[@class="base2"]/tr[2]/td[2]'
		coupon_this_month_xpath = '//table[@class="base2"]/tr[3]/td[2]'
		coupon_prev_month_xpath = '//table[@class="base2"]/tr[4]/td[2]'
		
		# 取得実行
		@agent.get( uri_coupon )
		@agent.log.info "Coupon page title: " + @agent.page.title
		#@agent.log.debug @agent.page.body.toutf8
		
		total = getNumericData_xpath( @agent.page, coupon_total_xpath )
		this_month = getNumericData_xpath( @agent.page, coupon_this_month_xpath )
		prev_month = getNumericData_xpath( @agent.page, coupon_prev_month_xpath )
		
		@agent.log.debug "Coupon data: total=#{total}, this_month=#{this_month}, prev_month=#{prev_month}"
		
		return [ total, this_month, prev_month ]
	end
	
	#
	# === Xpathで指定された箇所の数値を取得する
	#
	# ==== 引数
	#
	# page:: ページオブジェクト (Mechanize::Page)
	# xpath:: XPath (String)
	#
	# ====戻り値
	#
	# 数値 (Numeric)
	#
	def getNumericData_xpath( page, xpath )
		contents = page.at( xpath )
		
		if contents then
			@agent.log.debug "getNumericData_xpath: " + contents.inner_text.toutf8
			return contents.inner_text.to_i
		else
			return 0
		end
	end
	
	#
	# === 日本語で書かれた時刻情報をTimeオブジェクトに変換
	#
	# ==== 引数
	#
	# str:: 時刻情報文字列 (String)
	#
	# ====戻り値
	#
	# 時間 (Time)
	#
	def parseDate( str )
		if /[\s　]*(\d+)年[\s　]*(\d+)月[\s　]*(\d+)日/ =~ str then
			return Time::local( $1, $2, $3 )
		else
			return nil
		end
	end
end

