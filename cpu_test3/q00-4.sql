SELECT name,value,severity FROM stats WHERE value<>0 AND severity <> 'info' ORDER BY name;
