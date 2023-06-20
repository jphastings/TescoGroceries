# Tesco Grocery API
A seriously simple library for accessing the Tesco Grocery API.

## Preparations
The first step here is to register (https://secure.techfortesco.com/tescoapiweb/) at the Tech for Tesco so you can use their Grocery API.
Some of the calls (like working with baskets) will require non-anonymous login, so you may also want a Tesco account. They don't use any Oauth type stuff, you'll just need a username and password.

## Examples

Everyone loves examples. You don't want to read through all the documentation to get started!

	require 'tesco'
	
	t = Tesco::Groceries.new('dev_key','api_key')
	
	# Returns a Products object (see below, it's basically a read-only array)
	s = t.search("Chocolates")
	
	# Check out the Product class for more info about these badboys.
	p milky = s[0]
	# => Tesco Milk Chocolate Big Buttons 170G
	
	# Now you'll need to log in:
	t.login('joebloggs@tesco.com','supersecret!')
	
	# This will return *the* instance (ie. calling it twice will give you the same object)
	# of the basket for t's currently logged in user.
	b = t.basket
	
	# You can arrange products in the basket like so:
	b < milky # Push into the basket (or increment quantity)
	b > milky # Completely remove from the basket
	# b[milky] is now a 'BasketItem' Object, which you can use to alter amounts and the shopper note.
	b[milky].quantity = 5 # Set a specific quantity
	b[milky].note = "Please say \"I'm the Milky Bar Kid!\" as you pick it up. Please!"
	
	# Potentially counter-intuitive, request
	
	# There can only ever be one basket instance per logged in user:
	b.object_id == t.basket.object_id # => true
	
	# But logging in as a new user won't bugger things up:
	t.login('fredsmith@tesco.com','supersecreter!')
	b2 = t.basket
	b.customer_id  # => 1234
	b2.customer_id # => 5678
	
	# And it'll make sure you're not going to bugger things up:
	b > milky
	# NotAuthenticatedError, Please reauthenticate as this basket's owner before attempting to modify it
	
	
### The Products Class
As with most APIs that cover loads of information, the data is usually paginated. In order to make life simple I've designed this library so you don't have to worry about that at all. Paginated responses are 

### Keeping up with Tesco API development	
The default endpoint for the service is currently the  beta 1 (http://www.techfortesco.com/groceryapi_b1/RESTService.aspx). You can alter this after instantiating a Tesco object with:

	t.endpoint = "http://another.tesco.api/testing"

I'll endeavour to keep this library as up to date as I can, but in the event that there's a method you want to use that I haven't created you can either hack at the code by forking the repo on Github (http://github.com/jphastings/TescoGroceries) or you can just do this:

	t.the_new_api_call(:searchtext => "A string!", :becool => true)

This will send the command to the Tesco API as 'THENEWAPICALL' with the parameters in tow. You'll get a Hash back of the parsed JSON that comes direct from the API, so no fancy objects/DSL to work with, but the `api_request` method (which does all the hard work) *will* raise a subclass of TescoApiError if your request was dodgey, as per usual.