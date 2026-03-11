#!/bin/bash
sudo systemctl stop postgresql@18-logical
sudo systemctl stop postgresql@18-replica2
sudo systemctl stop postgresql@18-replica1
sudo systemctl stop postgresql@18-primary
sudo systemctl stop postgresql@18-analytics
