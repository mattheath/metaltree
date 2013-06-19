class Property
  include Dynamoid::Document

  table :name => :properties, :key => :id

  field :title
  field :url
  field :provider
  field :provider_id

  field :description

  field :room_type
  field :property_type
  field :seller_type

  field :couples, :boolean
end
