import 'dart:async';

import 'package:yahoo_finance_data_reader/src/daily/auxiliary/join_prices.dart';
import 'package:yahoo_finance_data_reader/src/daily/auxiliary/strategy_time.dart';
import 'package:yahoo_finance_data_reader/src/daily/mixer/average_mixer.dart';
import 'package:yahoo_finance_data_reader/src/daily/mixer/weighted_average_mixer.dart';
import 'package:yahoo_finance_data_reader/src/daily/model/yahoo_finance_candle_data.dart';
import 'package:yahoo_finance_data_reader/src/daily/model/yahoo_finance_configs.dart';
import 'package:yahoo_finance_data_reader/src/daily/model/yahoo_finance_response.dart';
import 'package:yahoo_finance_data_reader/src/daily/services/yahoo_finance_daily_reader.dart';
import 'package:yahoo_finance_data_reader/src/daily/storage/yahoo_finance_dao.dart';

/// This class abstracts for the state machine how the API vs cache works
class YahooFinanceService {
  // Singleton
  static final YahooFinanceService _singleton = YahooFinanceService._internal();

  factory YahooFinanceService() => _singleton;

  YahooFinanceService._internal();

  /// Fetches and mixes ticker data based on the weighted symbols
  Future<List<YahooFinanceCandleData>> getWeightedTickerData(
    String weightedSymbols, {
    bool useCache = true,
    required bool adjust,
  }) async {
    final Map<String, double> weightsAndSymbols =
        _parseWeightedSymbols(weightedSymbols);
    final Map<List<YahooFinanceCandleData>, double> weightedPrices = {};

    for (final String symbol in weightsAndSymbols.keys) {
      final double weight = weightsAndSymbols[symbol]!;
      final List<YahooFinanceCandleData> prices = await _directGetTickerData(
        symbol,
        useCache: useCache,
        adjust: adjust,
      );

      weightedPrices[prices] = weight;
    }

    return WeightedAverageMixer.mix(weightedPrices);
  }

  /// Parses the input into a map from symbol to it's weight
  Map<String, double> _parseWeightedSymbols(String weightedSymbols) {
    final Map<String, double> weightsAndSymbols = {};
    final symbolParts =
        weightedSymbols.split(YahooFinanceConfigs.tickersSeparator);

    for (int i = 0; i < symbolParts.length; i++) {
      final part = symbolParts[i].trim();
      final symbol = part.split(YahooFinanceConfigs.weightSeparator)[0];
      final double? weight =
          double.tryParse(part.split(YahooFinanceConfigs.weightSeparator)[1]);

      // If the weight is null, the symbol is invalid
      if (weight == null) {
        weightsAndSymbols[part] = 1 / symbolParts.length;
      } else {
        weightsAndSymbols[symbol] = weight;
      }
    }

    return weightsAndSymbols;
  }

  Future<List<YahooFinanceCandleData>> getTickerDataList(
    List<String> symbols, {
    bool useCache = true,
  }) async {
    final List<List<YahooFinanceCandleData>> pricesList = [];

    for (final String symbol in symbols) {
      final List<YahooFinanceCandleData> prices = await getTickerData(
        symbol,
        useCache: useCache,
      );

      pricesList.add(prices);
    }

    return AverageMixer.mix(pricesList);
  }

  /// Gets the candles for a ticker
  Future<List<YahooFinanceCandleData>> getTickerData(
    String symbol, {
    bool useCache = true,
    DateTime? startDate,
    bool adjust = false,
  }) async {
    if (symbol.contains(YahooFinanceConfigs.weightSeparator)) {
      return getWeightedTickerData(
        symbol,
        useCache: useCache,
        adjust: adjust,
      );
    } else if (symbol.contains(YahooFinanceConfigs.tickersSeparator)) {
      final List<String> symbols =
          symbol.split(YahooFinanceConfigs.tickersSeparator);
      return getTickerDataList(
        symbols,
        useCache: useCache,
      );
    }

    return _directGetTickerData(
      symbol,
      useCache: useCache,
      startDate: startDate,
      adjust: adjust,
    );
  }

  Future<List<YahooFinanceCandleData>> refreshData(
    List<YahooFinanceCandleData> pricesParam,
    String symbol, {
    DateTime? startDate,
    bool adjust = false,
  }) async {
    List<YahooFinanceCandleData> prices = pricesParam;

    if (prices.length > 1) {
      // Get one of the lasts dates in the cache, this is not the most recent,
      // because the most recent often is in the middle of the day,
      // and the yahoo finance returns us the current price in the close price column,
      // and for joining dates, we need real instead of the real close prices
      final DateTime lastDate = prices[2].date;

      final YahooFinanceResponse response =
          await const YahooFinanceDailyReader().getDailyDTOs(
        symbol,
        startDate: lastDate,
        adjust: adjust,
      );
      final List<YahooFinanceCandleData> nextPrices = response.candlesData;

      if (nextPrices != <YahooFinanceCandleData>[]) {
        prices = JoinPrices.joinPrices(prices, nextPrices);

        final List<dynamic> jsonList =
            YahooFinanceResponse(candlesData: prices).toCandlesJson();
        // Cache data after join locally
        unawaited(YahooFinanceDAO().saveDailyData(symbol, jsonList));
        return prices;
      }
    }

    // If was not possible to refresh, get all data from yahoo finance
    return getAllDataFromYahooFinance(
      symbol,
      startDate: startDate,
    );
  }

  /// Gets all data from yahoo finance
  Future<List<YahooFinanceCandleData>> getAllDataFromYahooFinance(
    String symbol, {
    bool useCache = true,
    DateTime? startDate,
    bool adjust = false,
  }) async {
    YahooFinanceResponse response = YahooFinanceResponse();

    // Get data from yahoo finance
    try {
      response = await const YahooFinanceDailyReader()
          .getDailyDTOs(symbol, adjust: adjust);
    } catch (e) {
      return [];
    }

    if (response.candlesData.isNotEmpty) {
      // Cache data locally

      final List<dynamic> jsonList = response.toCandlesJson();

      if (useCache) {
        unawaited(YahooFinanceDAO().saveDailyData(symbol, jsonList));
      }

      // Remove all candles before start date
      if (startDate != null) {
        response.candlesData
            .removeWhere((candle) => candle.date.isBefore(startDate));
      }

      return response.candlesData;
    }

    return [];
  }

  Future<List<YahooFinanceCandleData>> _directGetTickerData(
    String symbol, {
    required bool useCache,
    DateTime? startDate,
    required bool adjust,
  }) async {
    // Try to get data from cache
    List<dynamic>? pricesRaw;
    if (useCache) {
      pricesRaw = await YahooFinanceDAO().getAllDailyData(symbol);
    }

    List<YahooFinanceCandleData> prices = [];

    for (final priceRaw in pricesRaw ?? []) {
      final YahooFinanceCandleData price = YahooFinanceCandleData.fromJson(
        priceRaw as Map<String, dynamic>,
        adjust: adjust,
      );
      final bool isAfterStartDate =
          startDate == null || price.date.isAfter(startDate);

      if (isAfterStartDate) {
        prices.add(price);
      }
    }

    // If have no cached historical data
    if (prices.isEmpty) {
      prices = await getAllDataFromYahooFinance(
        symbol,
        useCache: useCache,
        startDate: startDate,
        adjust: adjust,
      );
    }

    // If there is offline data but is not up to date
    // try to get the remaining part
    else if (!StrategyTime.isUpToDate(prices, startDate)) {
      prices = await refreshData(
        prices,
        symbol,
        startDate: startDate,
        adjust: adjust,
      );
    }

    return prices;
  }
}
