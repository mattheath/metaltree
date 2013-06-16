require 'open-uri'
require 'nokogiri'
require 'aws'
require 'active_support/all'

aws_access_key_id = ''
aws_secret_access_key = ''

queue_name = 'properties'

# Get started with SQS in the EU
sqs_client = AWS::SQS.new(
  :access_key_id => aws_access_key_id,
  :secret_access_key => aws_secret_access_key,
  :sqs_endpoint => 'sqs.eu-west-1.amazonaws.com'
)

# Ensure our queue exists
begin
  queue = sqs_client.queues.create(queue_name)
  puts "Queue Created: " + queue.url
rescue => err
  puts err.to_s
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

# Our base uri
uri = "http://www.gumtree.com/flatshare/london/page"

# Starting page
page = 1

results_found = true
while results_found do

  puts "loading page #{page}"
  doc = Nokogiri::HTML(open("#{uri}#{page}"))
  items = doc.css('#search-results > ul:not(.featured) li.hlisting')

  puts "Found #{items.length} results on page #{page}"

  # Abort if there are no more results
  results_found = false if items.length == 0

  # Run through results
  items.each do |item|

    id = item.css("a.description")[0]['id'].scan(/\d+/).first
    title = item.css("h3")
    link = item.css("a")[0]['href']

    puts "Title: #{title}"
    puts "Gumtree ID: #{id}"
    puts "Link: #{link}"
    puts ""
  end

  # increment page number
  page += 1

  # rate limit if we did have results before checking next page
  sleep 1 if items.length > 0

end

puts "No more results"
