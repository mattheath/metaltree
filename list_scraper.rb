require 'toml'
require 'chronic'
require 'open-uri'
require 'nokogiri'
require 'aws'
require 'active_support/all'
require 'dynamoid'

project_root = File.dirname(File.absolute_path(__FILE__))

# Load Config
path = File.join(File.dirname(__FILE__), 'config', 'config.toml')
CONFIG = TOML.load_file(path)

# Base uri we'll scrape
uri = CONFIG['uri']

# Starting page
page = 1

# Maximum posted age to consider (abort after this point)
max_age = Chronic.parse(CONFIG['max_age'])
puts "Max age: #{max_age} #{max_age.to_i}"

# Should we rescrape previously gathered properties?
rescrape_properties = CONFIG['rescrape_properties'] || false

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

# Start scraping!
continue_scraping = true
results_found = true
max_remaining_pages = 2
while continue_scraping do

  already_scraped_page = false

  puts "loading page #{page}"
  doc = Nokogiri::HTML(open("#{uri}#{page}"))
  items = doc.css('#search-results > ul:not(.featured) li.hlisting')

  puts "Found #{items.length} results on page #{page}"

  # Abort if there are no more results
  results_found = false if items.length == 0

  # Run through results
  items.each do |item|

    id = item.css("a.description")[0]['id'].scan(/\d+/).first.strip

    puts id

    gp = GumtreeProperty.find(id)
    already_scraped = !! gp

    if already_scraped
      puts "Already Scraped this property (#{id}) \n"
      already_scraped_page = true
    else
      puts "Not scraped...\n"
    end

    # Scrape remainder of link
    title     = item.css("h3")[0].content.strip[0...100]
    link      = item.css("a")[0]['href'].strip
    puts item.css("span.dtlisted")[0]['title'].strip
    created   = Time.strptime(item.css("span.dtlisted")[0]['title'].strip, '%Y-%m-%dT%H:%M:%S%z').utc
    timestamp = created.to_i

    # Build our message
    message = {
      "link"        => link,
      "provider"    => "gumtree",
      "provider_id" => id,
      "title"       => title,
      "created"     => timestamp
    }

    puts message.to_json

    # Over maximum age?
    if timestamp < max_age.to_i
      puts "over max age!"
      continue_scraping = false
    end

    # Send message
    status = queue.send_message message.to_json
    puts "Sent with id: #{status.message_id}"
    puts "" # vertical space, yo

  end

  # increment page number
  page += 1

  # if we've already encountered a result on this page decrement the max remaining pages by one
  if already_scraped_page && !rescrape_properties
    max_remaining_pages = max_remaining_pages - 1
    puts "\n\n\n\n\n\n\n"
    puts "***** Decrementing remaining pages by 1 *****"
    puts "\n\n\n\n\n\n\n"
  end

  # rate limit if we did have results before checking next page
  sleep 1 if items.length > 0

  # Only continue if we still have results, and we've not run out of pages we want to scrape
  unless results_found && max_remaining_pages > 0
    puts "Shutting down scraper..."
    continue_scraping = false
  end

end

puts "No more results"
