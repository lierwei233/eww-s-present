# 美团 Top 1 接入

## 范围

「此刻」只从产品自有的 HTTPS 服务读取一条外卖建议。macOS 客户端不保存美团的开发者密钥、签名材料或用户账号信息；这些只应位于服务端的密钥管理系统中。

当服务未配置、定位不可用、接口超时或返回的数据无法校验时，客户端继续展示现有的示例餐食，并明确标注为示例，不把它描述为实时美团推荐。

## 接入前置条件

1. 申请美团开放平台或企业版的外卖/商家查询能力，并获得该合作范围内的开发者凭据。
2. 部署产品自有 HTTPS 代理服务，负责美团签名、权限校验、限流、缓存和错误处理。
3. 在客户端取得用户明确授权的位置后，将经纬度和必要的用餐时段传给代理。当前原型尚未发起定位授权；接入真实服务时必须补充该授权与撤销入口。
4. 由服务端按美团返回的可配送排序取第一项，并校验营业状态、配送范围、价格有效期和落地页。

美团的公开文档包含商家列表与菜品查询能力，但其接口面向已获授权的第三方渠道或企业客户，不能用客户端抓取普通美团 App 的页面数据。

## 客户端配置

服务上线后，在 macOS 运行：

```sh
defaults write com.cike.menubar MeituanRecommendationEndpoint -string "https://api.example.com/"
```

仅接受 HTTPS 地址。配置会保存在该 Mac 当前用户的偏好中。清除配置：

```sh
defaults delete com.cike.menubar MeituanRecommendationEndpoint
```

## 代理接口契约

`POST /v1/recommendations/meituan/top1`

请求：

```json
{
  "mealPeriod": "lunch",
  "locale": "zh_CN",
  "timeZone": "Asia/Shanghai"
}
```

真实接入定位后，请加入用户已授权的 `latitude`、`longitude` 与 `accuracyMeters`，不要传递微信文本或不相关的行为数据。

成功响应必须是美团排序第一项：

```json
{
  "source": "meituan",
  "rank": 1,
  "itemName": "照烧鸡腿饭",
  "description": "热食饱腹 · 少辣",
  "priceText": "¥29",
  "deliveryText": "预计 28 分钟送达",
  "shopName": "示例餐厅",
  "landingURL": "https://…",
  "updatedAt": "12:05"
}
```

服务端应在返回前核验 `rank`、营业状态、配送覆盖、价格和链接有效性；推荐超过短期缓存时限时应重新查询。下单始终在美团落地页内由用户确认。
