#!/bin/bash
sudo systemctl status postgresql@18-primary &1
sudo systemctl status postgresql@18-replica1
sudo systemctl status postgresql@18-replica2
sudo systemctl status postgresql@18-logical
sudo systemctl status postgresql@18-analytics
