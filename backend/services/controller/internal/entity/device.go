package entity

type Device struct {
	SN           string
	Model        string
	Customer     string
	Vendor       string
	Version      string
	ProductClass string
	Status       Status
	Mqtt         Status
	Stomp        Status
	Websockets   Status
}

type VendorsCount struct {
	Vendor string `bson:"_id" json:"vendor"`
	Count  int    `bson:"count" json:"count"`
}

type ProductClassCount struct {
	ProductClass string `bson:"_id" json:"productClass"`
	Count        int    `bson:"count" json:"count"`
}

type StatusCount struct {
	Status int `bson:"_id" json:"status"`
	Count  int `bson:"count" json:"count"`
}
