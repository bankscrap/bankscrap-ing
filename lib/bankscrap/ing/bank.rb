require 'bankscrap'

require 'json'
require 'base64'
require 'zlib'
require 'levenshtein'

require_relative './config'

module Bankscrap
  module ING
    class Bank < ::Bankscrap::Bank
      BASE_ENDPOINT      = 'https://ing.ingdirect.es'.freeze
      LOGIN_ENDPOINT     = "#{BASE_ENDPOINT}/genoma_login/rest/session".freeze
      POST_AUTH_ENDPOINT = "#{BASE_ENDPOINT}/genoma_api/login/auth/response".freeze
      CLIENT_ENDPOINT    = "#{BASE_ENDPOINT}/genoma_api/rest/client".freeze
      PRODUCTS_ENDPOINT  = "#{BASE_ENDPOINT}/genoma_api/rest/products".freeze

      REQUIRED_CREDENTIALS = %i(dni password birthday).freeze

      CURRENCY = Money::Currency.new('EUR')

      def initialize(credentials = {})
        super do
          @password = @password.to_s
        end
      end

      def balances
        log 'get_balances'
        balances = {}
        total_balance = 0
        @accounts.each do |account|
          balances[account.description] = account.balance
          total_balance += account.balance
        end

        balances['TOTAL'] = total_balance
        balances
      end

      def fetch_accounts
        log 'fetch_accounts'
        add_headers(
          'Accept'       => '*/*',
          'Content-Type' => 'application/json; charset=utf-8'
        )

        JSON.parse(get(PRODUCTS_ENDPOINT)).map do |account|
          build_account(account) if account['iban']
        end.compact
      end

      def fetch_investments
        log 'fetch_investments'
        add_headers(
          'Accept'       => '*/*',
          'Content-Type' => 'application/json; charset=utf-8'
        )

        JSON.parse(get(PRODUCTS_ENDPOINT)).map do |investment|
          build_investment(investment) if investment['investment']
        end.compact
      end

      def fetch_transactions_for(account, start_date: Date.today - 1.month, end_date: Date.today)
        log "fetch_transactions for #{account.id}"

        params = build_transactions_request_params(start_date, end_date)
        transactions = []
        loop do
          request = get("#{PRODUCTS_ENDPOINT}/#{account.id}/movements", params: params)
          json = JSON.parse(request)
          transactions += (json['elements'] || []).map do |transaction|
            build_transaction(transaction, account)
          end
          params[:offset] += params[:limit]
          break if (params[:offset] > json['total']) || json['elements'].blank?
        end
        transactions
      end

      def build_transactions_request_params(start_date, end_date)
        # The API allows any limit to be passed, but we better keep
        # being good API citizens and make a loop with a short limit
        {
          fromDate: start_date.strftime('%d/%m/%Y'),
          toDate: end_date.strftime('%d/%m/%Y'),
          limit: 25,
          offset: 0
        }
      end

      private

      def login
        ticket = pass_pinpad(request_pinpad_positions)
        post_auth(ticket)
      end

      def request_pinpad_positions
        add_headers(
          'Accept'       => 'application/json, text/javascript, */*; q=0.01',
          'Content-Type' => 'application/json; charset=utf-8'
        )

        params = request_pinpad_positions_params
        response = JSON.parse(post(LOGIN_ENDPOINT, fields: params.to_json))
        pinpad_numbers = recognize_pinpad_numbers(response['pinpad'])

        correct_positions(pinpad_numbers, response['pinPositions'])
      end

      def request_pinpad_positions_params
        {
          loginDocument: {
            documentType: 0,
            document: @dni
          },
          birthday: @birthday.to_s,
          companyDocument: nil,
          device: 'desktop'
        }
      end

      def pass_pinpad(positions)
        fields = { pinPositions: positions }
        response = put(LOGIN_ENDPOINT, fields: fields.to_json)
        JSON.parse(response)['ticket']
      end

      def post_auth(ticket)
        add_headers(
          'Accept'       => 'application/json, text/javascript, */*; q=0.01',
          'Content-Type' => 'application/x-www-form-urlencoded; charset=UTF-8'
        )

        params = "ticket=#{ticket}&device=desktop"
        post(POST_AUTH_ENDPOINT, fields: params)
      end

      def extract_images_from_pinpad(pinpad)
        pinpad.map do |string|
          extract_info_from_encoded_png(string)
        end
      end

      def extract_info_from_encoded_png(encoded_png)
        decoded = Base64.decode64(encoded_png)
        # PNG format first bytes are headers that we can discard. We know where the data chunk starts,
        # so we can directly read the image data. See: https://www.w3.org/TR/PNG-Structure.html
        length  = decoded.slice(33, 4).unpack('L>').first
        data    = decoded.slice(41, length)
        Zlib::Inflate.inflate(data)       # We decompress the data
                     .delete("\u0000")    # Levenshtein distance doesn't work with null bytes
                     .slice(2_000, 5_000) # The whole image is too slow to compare, we can use a chunk in the middle.
      end

      # For each image received, we compare it with the images of the numbers we already know, in order to find
      # the most similar one (using Levenshtein's string comparison).
      #
      # Note: We can't compare directly the strings we received, even after base64 decoding them, because PNG format
      # compress with Zlib the data of the image.
      def recognize_pinpad_numbers(received_pinpad)
        received_pinpad_images = extract_images_from_pinpad(received_pinpad)
        sorted_pinpad_images = extract_images_from_pinpad(Config::SORTED_PINPAD)
        received_pinpad_numbers = []
        candidates = *0..9
        0.upto(9) do |i|
          number = find_more_similar_image(sorted_pinpad_images, received_pinpad_images[i], candidates)
          candidates.delete(number) # We can reduce our search space
          received_pinpad_numbers << number
        end
        received_pinpad_numbers
      end

      def find_more_similar_image(sorted_pinpad_images, image, candidates)
        more_similar_number = -1
        min = 99_999 # An arbitrary, high enough upper limit
        candidates.each do |j|
          l = Levenshtein.distance(image, sorted_pinpad_images[j])
          # If the distance is lower, we have found a better candidate
          if l < min
            min = l
            more_similar_number = j
          end
        end
        more_similar_number
      end

      def correct_positions(pinpad_numbers, positions)
        positions.map do |position|
          # Positions array is 1-based
          number_to_find = @password[position - 1].to_i
          pinpad_numbers.index(number_to_find)
        end
      end

      # Build an Account object from API data
      def build_account(data)
        Account.new(
          bank: self,
          id: data['uuid'],
          name: data['name'],
          balance: Money.new(data['balance'] * 100, CURRENCY),
          available_balance: Money.new(data['availableBalance'] * 100, CURRENCY),
          description: (data['alias'] || data['name']),
          iban: data['iban'],
          bic: data['bic']
        )
      end

      def build_investment(data)
        Investment.new(
          bank: self,
          id: data['uuid'],
          name: data['name'],
          balance: data['balance'],
          currency: CURRENCY.iso_code,
          investment: data['investment']
        )
      end

      # Build a transaction object from API data
      def build_transaction(data, account)
        amount = Money.new(data['amount'] * 100, CURRENCY)
        Transaction.new(
          account: account,
          id: data['uuid'],
          amount: amount,
          effective_date: Date.strptime(data['effectiveDate'], '%d/%m/%Y'),
          description: data['description'],
          balance: Money.new(data['balance'] * 100, CURRENCY)
        )
      end
    end
  end
end
