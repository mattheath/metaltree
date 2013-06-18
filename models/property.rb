class Property
  include Dynamoid::Document

  table :name => :properties, :key => :id

  field :title
  field :url
  field :provider
  field :provider_id

  field :description

  field :couples, :boolean
end
