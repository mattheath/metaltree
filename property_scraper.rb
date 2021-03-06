require 'toml'
require 'chronic'
require 'open-uri'
require 'nokogiri'
require 'aws'
require 'active_support/all'
require 'dynamoid'

project_root = File.dirname(File.absolute_path(__FILE__))

# Load Config
path = File.join(project_root, 'config', 'config.toml')
CONFIG = TOML.load_file(path)

debug = true

# Set our nokogiri user agent
user_agent = CONFIG['nokogiri']['user_agent']

# SQS queue to use
queue_name = CONFIG['aws']['sqs']['queue_name']

# Set up AWS config
AWS.config({
  :access_key_id => CONFIG['aws']['access_key_id'],
  :secret_access_key => CONFIG['aws']['secret_access_key'],
  :dynamo_db_endpoint => CONFIG['aws']['dynamodb']['endpoint'],
  :sqs_endpoint => CONFIG['aws']['sqs']['endpoint'],
})

# Se up Dynamoid adapter for DynamoDB
Dynamoid.configure do |config|
  config.adapter = 'aws_sdk' # This adapter establishes a connection to the DynamoDB servers using Amazon's own AWS gem.
  config.namespace = "nearhere" # To namespace tables created by Dynamoid from other tables you might have.
  config.warn_on_scan = true # Output a warning to the logger when you perform a scan rather than a query on a table.
  config.partitioning = false # Spread writes randomly across the database. See "partitioning" below for more.
  config.partition_size = 200  # Determine the key space size that writes are randomly spread across.
  config.read_capacity = 3 # Read capacity for your tables
  config.write_capacity = 2 # Write capacity for your tables
end

# Load models
Dir.glob(project_root + '/models/*', &method(:require))

# Get started with SQS in the EU
sqs_client = AWS::SQS.new

# Ensure our queue exists
begin
  queue = sqs_client.queues.create(queue_name)
  puts "Queue Created: " + queue.url
rescue => err
  puts err.to_s
  exit
end

# Grab a web page
def get_response(uri, options)

  url = URI.parse(uri)
  req = Net::HTTP::Get.new(uri)
  req.add_field('User-Agent', options['user-agent']) if options['user-agent']
  res = Net::HTTP.start(url.host, url.port) {|http| http.request(req) }

  raise "Error loading property - might not exist? Response code: #{res.code}" unless res.code == "200"

  res.body
end

# Wait until the queue is available
retry_count = 0
try_again = true
while try_again
  queues = sqs_client.queues

  puts "Queues:"
  puts queues.map(&:url)

  # Does our queue exist yet?
  if queues.map(&:url).to_s =~ /\/#{queue_name}/
    retry_count = 0
    try_again = false
    puts "Queue Found"
  else
    try_again = true
    retry_count += 1
    sleep(1)
    puts("Queue not available yet - polling (" + retry_count.to_s + ")")
  end
end


# Start polling the queue for pages to scrape
puts "Starting to poll for items in queue..."
queue.poll do |msg|
  puts "\nRECEIVED: #{msg.body}"
#end


  # Testing data
  #msg = {}

  # 1 - not available
  #msg['body'] = '{"link":"http://www.gumtree.com/p/flats-houses/double-room-with-own-bathroom-in-west-kensington-fulham-hammersmith-w14-located-a-few-minutes-w/1022132697","provider":"gumtree","provider_id":"1022132697","title":"Double room with own bathroom in West Kensington- Fulham, Hammersmith. w14 Located a few minutes w","created":1371380134}'

  # 2 - available
  #msg['body'] = '{"link":"http://www.gumtree.com/p/flats-houses/stratford-large-double-room-available-near-westfield-shopping-centregirls-only/1022132765","provider":"gumtree","provider_id":"1022132765","title":"Stratford-Large double room available near Westfield shopping centre(girls only)","created":1371380168}'

  #item = JSON.parse(msg['body'])

  #puts "\nRECEIVED: #{msg.body}"
  item = JSON.parse(msg.body)

  puts item

  # Look up the property ID to see if it already exists
  gp = GumtreeProperty.find(item['provider_id'])
  already_scraped = !! gp

  # Load the existing property if we've already scraped it
  if already_scraped
    p = Property.find(gp.property_id)
  else
    # Create a new lookup index
    gp = GumtreeProperty.new
    gp.gumtree_id = item['provider_id']

    # And a new property
    p = Property.new
  end

  # Scrape ALL the things
  puts "SCRAPING: #{item['link']}"

  begin
    doc = Nokogiri::HTML(get_response(item['link'], {"User-Agent" => user_agent}))
  rescue Exception => e
    puts e.message
    puts "Skipping #{item['provider']} property #{item['provider_id']}"
    next
  end

  if notice_msg = doc.at_css('#vip-description .notice')
    if notice_msg.content = 'Sorry, this ad is no longer available.'
      puts "Property no longer available"
      next
    else
      puts "unknown notice message? #{notice_msg.content}"
      next
    end
  else
    puts "We're good!"
  end

  title = doc.css("#primary-h1 span")[0].content
  attributes = doc.css("ul#vip-attributes li")

  # Run through attributes this property has
  # Attributes are at the top of the listing
  attributes.each do |attribute|

    attr_title = attribute.css("h3")[0].content.strip
    attr_value = attribute.css("p")[0].content.strip

    case attr_title
    when "Property type"
      p.property_type = attr_value.downcase
    when "Room type"
      p.room_type = attr_value.downcase
    when "Seller type"
      p.seller_type = attr_value.downcase
    when "Date available"
      p.availability_date = DateTime.strptime(attr_value, '%d/%m/%y').to_time.to_i
    when "Available to couples"
      p.couples = (attr_value.downcase == "yes")
    end
  end

  # Grab main description & tidy up linebreak cruft
  description = doc.css("#vip-description-text")[0].content.strip
  description.gsub! /\r\n/, "\n"
  description.gsub! /\r/, "\n"

  # Grab numeric value to calculate cost per month
  price = doc.css(".ad-price")[0].content
  cpm = price.gsub(/[^0-9]/, "").to_i
  if price.match /pw/
    puts "per week"
    cpm = (cpm * 52) / 12
  end

  # Parse the location from the static Map URL
  begin
    puts location = CGI.parse(URI.parse(doc.css(".open_map")[0]['data-target']).query)["center"][0].to_s
    p.latitude, p.longitude = location.split(",")
  rescue
    puts "Failed to parse location from property"
    p.latitude = nil
    p.longitude = nil
  end

  # Output details of property if in debug mode
  if debug
    puts "*** #{title}"
    puts "    price: #{price}"
    puts "    price per month: #{cpm}"
    puts "    property type: #{p.property_type}"
    puts "    room type: #{p.room_type}"
    puts "    seller: #{p.seller_type}"
    puts "    available: #{p.availability_date}"
    puts "    couples: #{p.couples}"
    puts "    lat: #{p.latitude}"
    puts "    lon: #{p.longitude}"
    puts "    created: #{item['created']}"
  end

  # Store property details
  p.title = title
  p.url = item['link']
  p.provider = item['provider']
  p.provider_id = item['provider_id']
  p.description = description
  p.price = price
  p.cpm = cpm
  p.posted = item['created']

  p.availability_date = p.availability_date ||= nil
  p.seller_type = p.seller_type ||= nil
  p.property_type = p.property_type ||= nil
  p.room_type = p.room_type ||= nil
  p.couples = p.couples ||= false

  p.save

  puts p.id

  # Update the gumtree => property index
  gp.property_id = p.id
  gp.save

end
