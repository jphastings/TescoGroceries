# encoding: UTF-8

# == Tesco API
# See the readme for examples and such.
# 
# = TODO
# * Evaluate usefulness of the Department/Aisle/Shelf class division currently used
# * Substitution with the basket?
# * Add some useful barcode features, maybe allow lookup of products by barcode?

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'digest/md5'
require 'delegate'

module Tesco

  # Unobtrusive modifications to the Class class.
  class Class
    # Pass a block to attr_reader and the block will be evaluated in the context of the class instance before
    # the instance variable is returned.
    def attr_reader(*params,&block)
      if block_given?
        params.each do |sym|
          # Create the reader method
          define_method(sym) do
            # Force the block to execute before we…
           self.instance_eval(&block)
            # … return the instance variable
            self.instance_variable_get("@#{sym}")
          end
        end
      else # Keep the original function of attr_reader
        params.each do |sym|
          attr sym
        end
      end
    end
  end

  # You'll need an API and Developer key from https://secure.techfortesco.com/tescoapiweb/
  class Groceries
    attr_accessor :endpoint
    attr_reader(:customer_name,:customer_forename, :customer_id, :branch_number) { raise NotAuthenticatedError if @anonymous_mode }
  
    # Instantiates a tesco object with your developer and application keys
    def initialize(developer_key,application_key)
      @endpoint = URI.parse('http://www.techfortesco.com/groceryapi_b1/RESTService.aspx')
      @developer_key = developer_key
      @application_key = application_key
    end
  
    # Sets the api endpoint as a URI object
    def endpoint=(uri)
      @endpoint = URI.parse(uri)
    end
  
    # Search Tesco's grocery product listing. Returns a list of Products in a special object that acts like a read-only array.
    def search(q)
      Products.new(self,api_request(:productsearch,:searchtext => q))
    end
  
    # List all products currently on offer
    def on_offer
      Products.new(self,api_request(:listproductoffers))
    end
  
    # List all favourite grocery items (requires a non-anonymous login)
    def favourites
      raise NotAuthenticatedError if @anonymous_mode
      Products.new(self,api_request(:listfavourites))
    end

    def departments
      @@shelves = []
      api_request(:listproductcategories)['Departments'].collect {|dept|
        dept['Aisles'].each do |aisle|
          aisle['Shelves'].each do |shelf|
            @@shelves.push(Shelf.new(self,shelf))
          end
        end
        Department.new(self,dept)
      }
    end
  
    # Returns a Basket instance, Tesco API keeps track of the items in your basket in between sessions (TODO: i think!)
    def basket
      Basket.new(self)
    end
  
    # Lists all the products in the given category, as determined from the shelf id. You're probably better off using #departments, then
    # #Department#aisles, then #Aisle#shelves then Shelf#products which is an alias for this method.
    #
    # ie. tesco.departments[0].aisles[0].shelves[0].products
    def products_by_category(shelf_id)
      raise ArgumentError, "#{shelf_id} is not a valid Shelf ID" if not shelf_id.to_i > 0
      Products.new(self,api_request(:listproductsbycategory,:category => shelf_id))
    end
  
    # A convenience method, this will search all the shelves by name and return an array of Shelf objects that match.
    #
    # You'll probably want to send a regexp with the case insensitive tag: /kitchen/i 
    def search_shelves(q)
      raise ArgumentError, "The argument needs to be a Regular Expression." if not q.is_a? Regexp
      departments if not @@shelves.is_a? Array
      @@shelves.select {|shelf| shelf.name =~ q }
    end

    # Authenticates as the given user or as anonymous with the default parameters. Anonymous login will occur automatically
    # upon any request if a login hasn't already occured
    def login(email = '',password = '')
      res = api_request(:login,:email => email, :password => password)
      @anonymous_mode = (res['ChosenDeliverySlotInfo'] == "Not applicable with anonymous login")
      # TODO:InAmendOrderMode
    
      # The Tesco API returns "Mrs. Test-Farquharson-Symthe" for CustomerName in anonymous mode, for now I'll not include this in the Ruby library
      if !@anonymous_mode # Not for anonymous mode
        @customer_forename = res['CustomerForename']
        @customer_name = res['CustomerName']
        @customer_id = res['CustomerId']
        @branch_number = res['BranchNumber']
      end
      @session_key = res['SessionKey']
      return true
    end
  
    # Are we in anonymous mode?
    def anonymous?
      !@anonymous_mode
    end

    # Send a command to the Tesco API directly using the keys set up already. It will return a parsed version
    # of the direct output from the RESTful service. Status codes other than 0 will still raise errors as usual.
    #
    # Useful if you want a little more control over the the results, shouldn't be necessary.
    def api_request(command,params = {})
      login if @session_key.nil? and command != :login # Do an anonymous login if we're not authenticated
      params.merge!({:sessionkey => @session_key}) if not @session_key.nil?
      params = {
        :command => command,
        :applicationkey => @application_key,
        :developerkey => @developer_key,
        :page => 1 # Will be overwritten by a page in params
      }.merge(params)

      json = Net::HTTP.get(@endpoint.host,@endpoint.path+"?"+params.collect { |k,v| "#{k}=#{URI::escape(v.to_s)}" }.join('&'))

      res = JSON::load(json)
      res[:requestparameters] = params

      case res['StatusCode']
      when 0
        # Everything went well
        return res
      when 200
        raise NotAuthenticatedError
        # TODO: Other status codes
      else
        p res
        raise TescoApiError, "Unknown status code! Something went wrong - sorry"
      end
    end

    # If there are any other (ie. new) Tesco API calls this will make them available directly:
    #
    # An api command 'SEARCHELECTRONICS' (if one existed) would be available as
    # #search_electronics(:searchtext => 'computer',:parameter1 => 'an option')
    def method_missing(method,params = {})
      api_request(method.to_s.gsub("_",""),params)
    end
  
    # Represents an individual grocery item, #healthier_alternative, #cheaper_alternative and #base_product are
    # populated as detailess Products. Requesting any information from these will retrieve full information from
    # the API.
    class Product
      attr_reader(:image_url, :name, :max_quantity, :offer) { details if @name.nil? }
      attr_reader :healthier_alternative, :cheaper_alternative, :base_product
      attr_reader :product_id

      # Don't use this yourself!
      #
      # The unusual initialization here is so that there is only ever one instance of each product.
      # This means that using #Products as keys in a hash will always work, and (as they're identical)
      # it'll also save memory.
      def self.new(api,product_id,more = nil) # :nodoc:
        raise ArgumentError, "Not a product id" if not product_id =~ /^\d+$/
        @@instances ||= {}
      
        # Make sure we only ever have on instance of each product
        # If we have an instance then we should just return that
        if @@instances[product_id]
          # If we've been passed more then set it as it'll be more up-to-date
          @@instances[product_id].instance_variable_set(:@more,more) if !more.nil?
          return @@instances[product_id] 
        end
      
        # We don't have an instance of this product yet, go ahead and make one
        new_product = self.allocate
        new_product.instance_variable_set(:@product_id,product_id)
        new_product.instance_variable_set(:@api,api)
        new_product.instance_variable_set(:@more,more)
        new_product.details if !more.nil?
        @@instances[product_id] = new_product
      end
    
      def inspect
        name
      end

      # Will refresh the details of the product.
      def details
        # If we had some free 'more' data from the instanciation we should use it!
        if @more
          more = @more
          remove_instance_variable(:@more)
        end
      
        # If we have no data then we should get it from the ProductId
        if more.nil?
          # TODO: check to see if there are more than one
          more = @api.api_request('productsearch',:searchtext => @product_id)['Products'][0]
        end
      
        @healthier_alternative = Product.new(@api,more['HealthierAlthernativeProductId']) rescue nil
        @cheaper_alternative = Product.new(@api,more['CheaperAlthernativeProductId']) rescue nil
        @base_product = Product.new(@api,more['BaseProductId']) rescue nil
        @image_url = more['ImagePath']
        # ProducyType?
        # OfferValidity?
        @name = more['Name']
        @max_quantity = more['MaximumPurchaseQuantity']
        @barcode = Barcode.new(more['EANBarcode'])
        @offer = Offer.new(more['OfferLabelImagePath'],more['OfferPromotion'],more['OfferValidity']) rescue nil
      end
    end

    # Represents a shopping basket.
    class Basket < Hash
      attr_reader :basket_id, :quantity, :customer_id
      attr_reader(:price, :multi_buy_savings, :clubcard_points) { sync } # These are calculated on the server, so we need to sync before returning them
    
      # You can initialize your own basket with Basket.new(tesco_api_instance), but I'd recommend using
      # #Tesco#basket.
      #
      # Because this object will sync with the Tesco server there can only ever be one instance. It will
      # keep track of different users' baskets. (Wipe this memory with #Basket#flush)
      def self.new(api)
        raise ArgumentError, "The argument needs to be a Tesco instance" if not api.is_a? Tesco::Groceries
        begin
          return @@basket[api.customer_id]
        rescue
          (@@basket ||= {})[api.customer_id] = self.allocate
          @@basket[api.customer_id].instance_variable_set(:@api,api)
          @@basket[api.customer_id].instance_variable_set(:@customer_id,api.customer_id)
          @@basket[api.customer_id].sync
          @@basket[api.customer_id]
        end
      end
    
      # This class keeps track of all the baskets for each user that's been logged in, to save on API calls.
      # If you need to remove this information from memory this method will destroy the class variable that holds
      # it, without affecting anything on the Tesco servers.
      def self.flush
        @@basket.clean
      end
    
      # Makes sure this object reflects the basket on Tesco online.
      def sync
        authtest
        res = @api.api_request(:listbasket)
        @basket_id = res['BasketId'].to_i
        @price = res['BasketGuidePrice'].to_f
        @multi_buy_savings = res['BasketGuideMultiBuySavings'].to_f
        @clubcard_points = res['BasketTotalClubcardPoints'].to_i
        @quantity = res['BasketQuantity'] # TODO: Is this just length?
      
        res['BasketLines'].each do |more|
          self[Product.new(@api,more['ProductId'],more)] = BasketItem.new(self,more)
        end
      
        return true
      end
    
      # Change the note for the shopper on a product in your basket
      def note(product,note) # TODO: should work with multiple products
        authtest
        raise IndexError, "That item is not in the basket" if not self[product]
        @api.api_request(:changebasket,:productid => product.product_id,:changequantity => 0,:noteforshopper => note)
        self[product].instance_variable_set(:@note,note)
      end
    
      # Adds the given product(s) to the basket. It increments that item's quantity if it's already present in the basket. Leave a note for the shopper against these items with note.
      def <(products)
        authtest
        [products].flatten.each do |product|
          raise ArgumentError, "That is not a Tesco Product object" if !product.is_a?(Tesco::Groceries::Product)
          (self[product] ||= BasketItem.new(self,{'ProductId' => product.product_id})).add(1)
        end
      end
      alias_method :add, :<
    
      # Removes the given product(s) completely from the basket.
      def >(products)
        authtest
        [products].flatten.each do |product|
          raise ArgumentError, "That is not a Tesco Product object" if !product.is_a?(Tesco::Groceries::Product)
          delete(product).remove # Removes the product from the basket, then deletes it from the API
        end
      end
      alias_method :remove, :>
    
      # Empties the basket completely — this may take a while for large baskets
      def clean
        authtest
        self.each_pair do |product,basket_item|
          delete(product).remove # Removes the product from the basket, then deletes it from the API
        end
      end
      
      # tests to make sure you are authenticated as this basket's owner
      def authtest
        raise NotAuthenticatedError, "Please reauthenticate as this basket's owner before attempting to modify it" if @customer_id != @api.customer_id
      end
    end
  
    # Assists in the modification of basketed products
    #
    # TODO: Correct basket auth?
    class BasketItem < DelegateClass(Product)
      attr_accessor :note, :quantity, :error_message, :promo_message
      # I wouldn't mess around with this from your code, its essentially internal
      def self.new(basket,more) # :nodoc:
        @basket = basket
        
        # With a little hackiness because Product initializes with self.new, not initialize
        basket_item = super(Product.new(basket.instance_variable_get(:@api),more['ProductId'],more))
        # Set it's instance variables
        basket_item.instance_variable_set(:@quantity,(more['BasketLineQuantity'].to_i rescue 0))
        basket_item.instance_variable_set(:@error_message,(more['BasketLineErrorMessage'] rescue "")) # TODO: Parse this
        basket_item.instance_variable_set(:@promo_message,(more['BasketLinePromoMessage'] rescue ""))
        basket_item.instance_variable_set(:@note,(more['NoteForPersonalShopper'] rescue ""))
        
        basket_item
      end
    
      # Update the server if the NoteForShopper is changed
      
      # TODO: set shopper note
      def note=(note)
        @basket.authtest
      end
      
      # Add a certain number of items to the basket
      def add(val = 1)
        @basket.authtest
        return remove if (@quantity + val) <= 0
        __getobj__.instance_variable_get(:@api).api_request(:changebasket,:productid => self.product_id,:changequantity => val,:noteforshopper => @note)  
        @quantity
      end
      
      # Remove a certain number of items from the basket
      def drop(val = 1)
        @basket.authtest
        add(val * -1)
      end
      
      # Alter the quantity to a specific amount
      def quantity=(amount)
        @basket.authtest
        return @quantity if @quantity == amount # No need to do anything if they're the same
        raise ArgumentError, "amount must be >= 0 and <= #{self.max_quantity}" if (not amount.is_a? Integer) or amount < 0 or amount > self.max_quantity
        __getobj__.instance_variable_get(:@api).api_request(:changebasket,:productid => self.product_id,:changequantity => amount - @quantity,:noteforshopper => @note)
        @quantity -= amount
      end
    
      # Remove this item from the basket completely
      def remove
        @basket.authtest
        @basket.remove(__getobj__)
      end
      
      def inspect
        @basket.authtest
        "#{@quantity} item"<<((@quantity == 1) ? "" : "s")
      end
    end

    class Department
      attr_reader :id, :name
      # No point in creating these by hand
      def initialize(api,details) # :nodoc:
        @id = details['Id']
        @name = details['Name']
        @aisles = details['Aisles'].collect { |aisle|
          Aisle.new(api,aisle)
        }
      end
    
      # Lists all aisles in this department. Each item is an Aisle object
      def aisles
        @aisles
      end
    
      def inspect
        "#{@name} Department"
      end
    end
  
    class Aisle
      attr_reader :aisle_id, :name
      # No point in creating these by hand.
      def initialize(api,details) # :nodoc:
        @id = details['Id']
        @name = details['Name']
        @shelves = details['Shelves'].collect { |shelf|
          Shelf.new(api,shelf)
        }
      end
    
      # Lists all shelves in this aisle. Each item is a Shelf object
      def shelves
        @shelves
      end
    
      def inspect
        "#{@name} Aisle"
      end
    end
  
    class Shelf
      attr_reader :department,:aisle, :aisle_id, :name
      # No point in creating these by hand.
      def initialize(api,details) # :nodoc:
        @api = api
        @id = details['Id']
        @name = details['Name']
      end
    
      def products
        @api.products_by_category(@id)
      end
    
      def inspect
        "#{@name} Shelf"
      end
    end
  
    # A special class that takes care of product pagination automatically. It'll work like a read-only array for the most part
    # but you can request a specific page with #page and requesting a specific item with #[] will request the required page automatically
    # if it hasn't already been retrieved and stored within the instance's cache.
    class Paginated
      attr_reader :length, :pages
      # Don't use this yourself!
      def initialize(api,res) # :nodoc:
        @cached_pages = {}
        @api = api
        # Do the page we've been given (usually the first)
        @cached_pages[res['PageNumber'] || 1] = parse_items(res)
        @pages = res['TotalPageCount'] || 1
        @perpage = res['PageProductCount']
        @length = res['TotalProductCount'] || @perpage
        @params = res[:requestparameters]
      end
    
      # Will return the item at the requested index, even if that page hasn't yet been retreived
      def [](n)
        raise TypeError, "That isn't a valid array reference" if not (n.is_a? Integer and n >= 0)
        raise PaginationError, "That index exceeds the number of items" if n >= @length
        page_num = (n / @perpage).floor + 1
        page(page_num)[n - page_num * @perpage]
      end
    
      # Will return all the items on the requested page (indeces will be relative to the page).
      # Specifying page = 0 or page = :all will give an array of all items, retrieving all details first
      # This could take a very, vey long time!
      def page(page)
        page = 0 if page == :all
        raise PaginationError, "That isn't a valid page reference" if not (page.is_a? Integer and page >= 0 and page <= @pages)
        if !@cached_pages.keys.include?(page)
          @cached_pages[res['PageNumber'] || 1] = parse_items(@api.api_request(nil,@params.merge({:page => page})))
        end
        @cached_pages[page]
      end
    
      # Akin to Array#each, except you must specify which page, or range of pages, of products you wish to iterate over.
      #
      # Specifying page = 0 or page = :all will iterate over every item on every page
      #
      # The items on each page will be passed to your block as they're retrieved, so you'll get spurts of output.
      #
      # NB. This method won't check your enumberable for each item being a valid page until it's processed all prior pages.
      def each(pages = :all)
        pages = (1..@pages) if (pages == :all or pages == 0)
        pages = [pages] if not pages.is_a? Enumerable
        pages.each do |page|
          raise PaginationError, "#{page.inspect} isn't a valid page reference" if not (page.is_a? Integer and page >= 0 and page <= @pages)
          page(page).each do |item|
            yield item
          end
        end
      end
    
      def inspect
        output = ""
        previous = 0
        @cached_pages.each_pair do |page,content|
          output << ", … #{(page - previous) * @perpage} more …" if (previous + 1) != page
          output << ", " << content.inspect[1..-2]
          previous = page
        end
        output << ", … #{@length - previous * @perpage} more" if previous != @pages
        "[#{output[2..-1]}]"
      end
    
      private
      # There's no parsing for the default pagination class, make a subclass and write your own parse method
      # Take a look at #Products if you want to see how it's done.
      def parse_items(res); res; end
    end
  
    # Deals with the specifics of paginating products.
    class Products < Paginated
      private
      def parse_items(res)
        res['Products'].collect{|json|
          Product.new(@api,json['ProductId'],json)
        }
      end
    end
  
    class Offer
      attr_reader :image_url, :description, :validity
      attr_reader :valid_from, :valid_until
    
      # No point in making these by hand!
      def initialize(image_url,descr,validity) # :nodoc:
        raise ArgumentError, "Not a valid offer" if descr.nil? or descr.empty?
        @description = descr
        @image_url = image_url
        @validity = validity
        @valid_from, @valid_until = Time.utc($3,$2,$1), Time.utc($6,$5,$4) if validity =~ /^valid from (\d{1,2})\/(\d{1,2})\/(\d{4}) until (\d{1,2})\/(\d{1,2})\/(\d{4})$/
      end
    end

    private
    class PaginationError < IndexError; end
    class TescoApiError < RuntimeError
      def to_s; "An unspecified error has occured on the server side."; end
    end
    class NoSessionKeyError < TescoApiError
      def to_s; "The session key has been declined, try logging in again."; end
    end
    class NotAuthenticatedError < TescoApiError
      def to_s; "You must be an authenticated non-anonymous user."; end
    end
  end

  class Barcode
    def initialize(code)
      @barcode = code.to_s
    end

    def to_s
      @barcode
    end
  end
end