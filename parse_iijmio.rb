#!/usr/bin/ruby -w
#
# = IIJmioパーサ
#

$KCODE='UTF8'

require 'kconv'
require 'open-uri'
require 'uri'
require 'logger'

require 'rubygems'
require 'nokogiri'
require 'mechanize'

#
# = IIJmioパーサクラス
#
# == 処理に使う諸々
# 
# - ログイン画面： https://www.iijmio.jp/auth/login.jsp
# - 入力フォーム: <form method="POST" action="/j_security_check">
# - mioID: <input type="text" name="j_username" maxlength="10" value="" style="width:100px">
# - mioパスワード: <input type="password" name="j_password" maxlength="8" style="width:100px">
# - データ利用量: https://www.iijmio.jp/service/setup/hdd/viewdata/
# - クーポン残量: https://www.iijmio.jp/service/setup/hdd/couponstatus/
# - ログアウト: https://www.iijmio.jp/auth/logout.jsp
#
class IIJmioParser
	
	#
	# === 初期化
	#
	# 下記の検索パラメータを設定する。
	#   - mioID
	#   - mioパスワード
	#   - 各種URL
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
		
		# 各種URL
		@uri_login = 'https://www.iijmio.jp/auth/login.jsp'
		@uri_logout = 'https://www.iijmio.jp/auth/logout.jsp'
		@uri_data = 'https://www.iijmio.jp/service/setup/hdd/viewdata/'
		@uri_coupon = 'https://www.iijmio.jp/service/setup/hdd/couponstatus/'
		
		# ログインフォーム情報
		@login_form_action = '/j_security_check'
		@login_form_id = 'j_username'
		@login_form_pass = 'j_password'
		
		# クーポン残量取得用XPath
		@coupon_xpath = '//table[@class="base2"]/tr[2]/td[2]'
		
		# データ利用量取得用XPath
		@history_xpath = '//table[@class="base2"]/tr'
		
		# 結果格納用変数の初期化
		@history = nil
		@rest = 0
		
		# Mechanize agent
		@agent = Mechanize.new
		
		if logger.is_a?(Logger) then
			@agent.log = logger
		else
			# log出力先のデフォルト値はSTDOUT出力 / LogLevel = WARN
			@agent.log = Logger.new(STDOUT)
			@agent.log.level = Logger::WARN
		end
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
		begin
			@agent.get(@uri_login)
			@agent.log.info "Page title: " + @agent.page.title
			@agent.page.form_with(:action => @login_form_action) do |form|
				form.field_with(:name => @login_form_id).value = @user_id
				form.field_with(:name => @login_form_pass).value = @user_pass
				form.click_button
			end
		rescue
			@agent.log.error $!
			return nil
		end
		
		# データ取得
		begin
			
			# データ利用量のページ
			@agent.get(@uri_data)
			@agent.log.info "Page title: " + @agent.page.title
			@history = getHistoryData(@agent.page)
			if @history then
				@history.each do |tel, data_hash|
					data_hash.each do |date, bytes|
						@agent.log.info "#{date.strftime('%Y/%m/%d')} (#{tel}) : #{bytes}MB"
					end
				end
			end
			
			# クーポン残量のページ
			@agent.get(@uri_coupon)
			@agent.log.info "Page title: " + @agent.page.title
			@rest = getCouponData(@agent.page)
			@agent.log.info "クーポン残量(総容量)： #{@rest}MB"
		
		rescue
			@agent.log.error $!
		ensure
			# エラー発生時でもログアウトだけは行う
			@agent.get(@uri_logout)
			@agent.log.info "Page title: " + @agent.page.title
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
			@history.each do |tel, data_hash|
				str += "\n○#{tel}\n"
				data_hash.sort.each do |date, bytes|
					str += "#{date.strftime('%Y/%m/%d')} : #{bytes}MB\n"
				end
			end
		end
		
		if @rest > 0 then
			str += "\n●クーポン残量(総容量)： #{@rest}MB\n"
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
	# page :: page (Mechanize::Page)
	#
	# ==== 戻り値
	#
	# Hash :: 電話番号をkeyとするHash。valueは日付をkeyとするHash
	# _false_ :: 取得失敗した場合
	#
	def getHistoryData(page)
		contents = page.search(@history_xpath)
		
		date = nil
		result = Hash.new
		
		# 取得失敗した場合は、falseを返す
		return false unless contents

		# 最初の2要素はヘッダなのでスキップ
		contents.drop(2).each do |node|
			
			if node.child['class'] == 'item2' then
				# 日付要素の場合
				date = parseDate(node.child.inner_text)
			else
				# データ要素の場合
				contents_data = node.xpath('./td')
				
				tel_number = contents_data[0].inner_text
				#icc_id = contents_data[1].inner_text
				sim_type = contents_data[2].inner_text
				lte_data = contents_data[3].inner_text.to_i
				restricted_data = contents_data[4].inner_text.to_i
				
				# Hashが作られていない場合作成
				unless result["#{tel_number}(#{sim_type})"] then
					result["#{tel_number}(#{sim_type})"] = Hash.new
				end
				
				# データ格納
				result["#{tel_number}(#{sim_type})"][date] = lte_data + restricted_data
				
			end
		end
		
		return result
	end
	
	# 
	# === クーポン残量取得
	#
	# ==== 引数
	#
	# page :: page (Mechanize::Page)
	#
	# ==== 戻り値
	#
	# 正の数 :: 総残量
	# 負の数 :: データ取得エラー
	#
	def getCouponData(page)
		contents = page.at(@coupon_xpath)
		
		if contents then
			return contents.inner_text.to_i
		else
			return -1
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
	def parseDate(str)
		if /[\s　]*(\d+)年[\s　]*(\d+)月[\s　]*(\d+)日/ =~ str then
			return Time::local($1, $2, $3)
		else
			return nil
		end
	end
end

