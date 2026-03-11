#!/bin/bash
sudo systemctl start postgresql@18-primary
sudo systemctl start postgresql@18-replica1
sudo systemctl start postgresql@18-replica2
sudo systemctl start postgresql@18-logical
sudo systemctl start postgresql@18-analytics
