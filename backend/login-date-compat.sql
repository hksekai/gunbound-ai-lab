USE gunbound;
SET @inactive_date = FROM_UNIXTIME(0);

UPDATE User
SET MuteTime = IF(MuteTime = '0000-00-00 00:00:00', @inactive_date, MuteTime),
    RestrictTime = IF(RestrictTime = '0000-00-00 00:00:00', @inactive_date, RestrictTime)
WHERE Id IN ('Player', 'BotOne') AND UNIX_TIMESTAMP(@inactive_date) = 0;

UPDATE GunWcUser
SET MuteTime = IF(MuteTime = '0000-00-00 00:00:00', @inactive_date, MuteTime),
    RestrictTime = IF(RestrictTime = '0000-00-00 00:00:00', @inactive_date, RestrictTime)
WHERE Id IN ('Player', 'BotOne') AND UNIX_TIMESTAMP(@inactive_date) = 0;

UPDATE Game
SET GiftProhibitTime = @inactive_date
WHERE Id IN ('Player', 'BotOne') AND GiftProhibitTime = '0000-00-00 00:00:00'
  AND UNIX_TIMESTAMP(@inactive_date) = 0;
