# Building a Comprehensive Token Minting and Migration (Super)Dashboard

The idea is to have a fairly simple UI which gives you a detail ONE-PAGE(this is important) graphical overview on newly created tokens/migrations from PumpFun.

---

What I really do not like about other platforms implementation is the layout they use.

Instead of displaying all the launches in a nice grid layout, where the user can really have a broader view of whats going on, they choose to use this tremendous three-cols view which make very hard for the user to actually see what's going on with the launches and post-migrations tokens.

![Photon Screenshot](/assets/Screenshot%202025-03-14%20at%2018.13.51.png)

Do someone really even understand this?

---

Another killing features that this kind of layout is missing is a **king of the hill** logic to visualize all the tokens.

Memecoins are literally attention and volume based, if some token start to gain traction there is an high probability of that to reach higher market caps and don't die off before the $100k MC.

Being able to see an a _"leaderboard"_ like layout, meaning being ordered based on their realtime performance(txs volume primarily) let you naturally see which token is beating all the others.

If you sum that with the ability to filter out **artificially inflated** volume, boom you got a killer layout.

![Dashboard Mockup](/assets/Screenshot%202025-03-14%20at%2023.44.19.png)

---

A non-trivial problem to solve is determining a _"death"_ criteria for each token:

- How long should a token being displayed after the launch?
- How we can say a token is in a _"death"_ state?

For us (humans) its a pretty easy task to immediately look at a coin and knowing if its still alive or not, but for an algorithm is essential we determine precise rules and criteria to evaluate that.

![Dead coin example](/assets/Screenshot%202025-03-15%20at%2023.30.11.png)

As you can see in the example above, a simple high volume/high txs number filter would catch a lot of false positives, to really filter out _"dead"_ tokens from _"live"_ ones we need a more intelligent solution.


---

And finally the last, but not for importance, of all problems: **scale and speed**.

A trading system of this kind demand for real-time speed and execution, this is <u>**mandatory**</u>.

In an environment where being fast and front-running competitors is what makes the difference between making and losing money, non-real time performance speed its just not an option.

Due to the large amount of transactions and token minting events that happens every seconds, and considering a potential high volume user traffic to the platform, is essential that scaling is a first option requirements during the design phase.

Code? Yes let's look at some (poorly written) Go code.

Go is a good choice cause it simplifies a lot the use of coroutines for parallelism and generally is also well known for performance when it comes to backend systems.

I'm going to show two different ways to handle Pumpfun **token minting** and **token migration events**, each of them using a different approach.

For the first one i'm simply going to use a very nice third party free data api which allows us to listen to newly launched token in real time via _websockets_.

```go
const QUEUE_SIZE_LIMIT int = 500

type MessageQueue struct {
	queue [QUEUE_SIZE_LIMIT][]byte
	index int
	mu sync.Mutex

	// msg/s computation
	messageCount uint64
	lastPrintTime time.Time
}
```

First we defined a simple queue data structure which will be used by the data producer, in this case our websocket connection, to keep storing every new message without being interrupted.

The messages in this queue can then be consumed by **one or more** consumer which can makes everything extremely fast ensuring we never lose a single token creation event.

Here's out data producer(_websocket connection_):

```go
func listenToNewToken(pmsgQueue *MessageQueue) {
	conn, _, err := websocket.DefaultDialer.Dial("wss://pumpportal.fun/api/data", nil)
	if err != nil {
		log.Fatal("dial:", err)
	}
	defer conn.Close()

	msg := `{"method": "subscribeNewToken"}`

	err = conn.WriteMessage(websocket.TextMessage, []byte(msg))
	if err != nil {
		log.Println("write:", err)
		return
	}

	// Skip the first message
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			log.Println("read:", err)
		}
		break
	}

	for {
		_, message, err := conn.ReadMessage()
		if err != nil {
			log.Println("read:", err)
			return
		}

		pmsgQueue.mu.Lock()
		if pmsgQueue.index < QUEUE_SIZE_LIMIT {
			pmsgQueue.queue[pmsgQueue.index] = message
			pmsgQueue.index += 1
			atomic.AddUint64(&pmsgQueue.messageCount, 1)
		} else {
			log.Println("Queue is full, skipping message.")
		}
		pmsgQueue.mu.Unlock()
	}
}
```

And this is a simple example of how a consumer can handle the data:

```go
type NewTokenMessage struct {
	Signature       string  `json:"signature"`
	Mint            string  `json:"mint"`
	TraderPublicKey string  `json:"traderPublicKey"`
	TxType          string  `json:"txType"`
	InitialBuy      float64 `json:"initialBuy"`
	SolAmount       float64 `json:"solAmount"`
	BondingCurveKey string  `json:"bondingCurveKey"`
	VTokensInBondingCurve float64 `json:"vTokensInBondingCurve"`
	VSolInBondingCurve float64 `json:"vSolInBondingCurve"`
	MarketCapSol     float64 `json:"marketCapSol"`
	Name             string  `json:"name"`
	Symbol           string  `json:"symbol"`
	Uri              string  `json:"uri"`
	Pool             string  `json:"pool"`
}

func prettyPrintNewTokenMsg(pnewTokenMsg *NewTokenMessage) {
	fmt.Printf("\n-----------------")
	fmt.Printf("\n%s New Token Mint  %s", "\033[92m", "\033[0m")
	fmt.Printf("\n-----------------")

	fmt.Printf("\n Name: %s", pnewTokenMsg.Name)
	fmt.Printf("\n Symbol: %s", pnewTokenMsg.Symbol)
	fmt.Printf("\n Tx Sig: %s", pnewTokenMsg.Signature)
	fmt.Printf("\n Mint: %s", pnewTokenMsg.Mint)
	fmt.Printf("\n Pool: %s", pnewTokenMsg.Pool)
	fmt.Printf("\n Token Creator: %s", pnewTokenMsg.TraderPublicKey)
	fmt.Printf("\n\n")
}

func main() {
	var pmessageQueue *MessageQueue = &MessageQueue{index: 0}
	pmessageQueue.lastPrintTime = time.Now()

	go listenToNewToken(pmessageQueue)

	for {
		if pmessageQueue.index > 0 {
			pmessageQueue.mu.Lock()
			var newMsg *NewTokenMessage = &NewTokenMessage{}
			err := json.Unmarshal(pmessageQueue.queue[pmessageQueue.index-1], newMsg)
			if err != nil {
				fmt.Println("error decoding msg:", err)
			} else {
				prettyPrintNewTokenMsg(newMsg)
			}
			pmessageQueue.index -= 1
			pmessageQueue.mu.Unlock()
		}
	}
}
```
![token minting monitor screenshot](/assets/Screenshot%202025-03-16%20at%2000.02.14.png)

---

Now let's look at a more complex task, **token migration** to Raydium.

As I did not find any convenient third party API, we are going to directly interface with public Solana Rpc Nodes via jsonrpc requests.

To do so we need to listen to the transactions made by the address which manages the Pumpfun pool and create the Raydium pools + burning all LP tokens upon completing the bonding curve.

The address is `39azUYFWPz3VHgKCf3VChUwbpURdCHRxjWVowf5jUJjg`

![migration manager address transactions](/assets/Screenshot%202025-03-16%20at%2000.10.12.png)

Here's how we can directly listen to all transactions logs for this specific account:

```go
type JSONRpcRequest struct {
	JsonRpc string `json:"jsonrpc"`
	Id uint64 `json:"id"`
	Method string `json:"method"`
	Params interface{} `json:"params"`
}

type JSONRpcResponse struct {
	JsonRpc string `json:"jsonrpc"`
	Result uint64 `json:"result"`
	Id uint64 `json:"id"`
}

type JSONRpcNotification struct {
	JsonRpc string `json:"jsonrpc"`
	Id string `json:"id"`
	Method string `json:"method"`
	Params interface{} `json:"params"`
	subscription string `json:"subscription"`
}
```

```go
func listenToAccount() {
	wsEndpoint := "ws://api.mainnet-beta.solana.com"
	conn, _, err := websocket.DefaultDialer.Dial(wsEndpoint, nil)
	if err != nil {
		log.Fatalf("Failed to connect to WebSocket: %v", err)
	}
	defer conn.Close()

	conn.SetPingHandler(func(data string) error {
		fmt.Println("received ping")
		return conn.WriteControl(websocket.PongMessage, []byte(data), time.Now().Add(10*time.Second))
	})

	// pining routine
	go func() {
        pingInterval := 15 * time.Second
        pingTimeout := 10 * time.Second
        ticker := time.NewTicker(pingInterval)
        defer ticker.Stop()
        
        for {
            select {
            case <-ticker.C:
                err := conn.WriteControl(websocket.PingMessage, []byte{}, time.Now().Add(pingTimeout))
                if err != nil {
                    log.Printf("Error sending ping: %v", err)
                    return
                }
                log.Printf("Ping sent")
            }
        }
    }()

	if METHOD == "account" {

		var accountSubMsg *JSONRpcRequest = &JSONRpcRequest{
			JsonRpc: "2.0",
			Id: 1,
			Method: "accountSubscribe",
			Params: []interface{}{
				PUMPFUN_RAYDIUM_MIGRATION_ADDRESS,
				map[string]string{
					"encoding": "jsonParsed",
					"commitment": "finalized",
				},
			},
		}

        // This method "accountSubscribe" is actually not useful cause it just notify us of new transaction without any detail about it
    }

	if METHOD == "logs" {
		var logsSubMsg *JSONRpcRequest = &JSONRpcRequest{
			JsonRpc: "2.0",
			Id: 1,
			Method: "logsSubscribe",
			Params: []interface{}{
				map[string][]string{
					"mentions": []string{PUMPFUN_RAYDIUM_MIGRATION_ADDRESS},
				},
				map[string]string{
					"commitment": "finalized",
				},
			},
		}

		encodedMsg, err := json.Marshal(logsSubMsg)
		fmt.Println(string(encodedMsg))
		if err != nil {
			log.Println("error encoding subscription msg:", err)
			return
		}

		err = conn.WriteMessage(websocket.TextMessage, encodedMsg)
		if err != nil {
			log.Println("write:", err)
			return
		}

		for {
			var logsSubMsg *JSONRpcResponse = &JSONRpcResponse{}
			_, message, err := conn.ReadMessage()
			if err != nil {
				log.Println("read:", err)
				return
			}

			err = json.Unmarshal(message, logsSubMsg)

			if err != nil {
				log.Println("error decoding subscription response:", err)
			}

			fmt.Printf("New message: %s\n", message)
			break
		}

		for {
			var notificationMsg *JSONRpcNotification = &JSONRpcNotification{}
			_, message, err := conn.ReadMessage()
			if err != nil {
				log.Println("read:", err)
				return
			}

			err = json.Unmarshal(message, notificationMsg)

			if err != nil {
				log.Println("error decoding notification response:", err)
			}

			paramsMap, ok := notificationMsg.Params.(map[string]interface{})
			if !ok {
				log.Println("params is not a map:", notificationMsg.Params)
				continue
			}

			result, ok := paramsMap["result"].(map[string]interface{})
			if !ok {
				log.Println("result is not a map or doesn't exist")
				return
			}
			
			value, ok := result["value"].(map[string]interface{})
			if !ok {
				log.Println("value is not a map or doesn't exist")
				return
			}
			
			signature, ok := value["signature"]
			if !ok {
				log.Println("no data in notification:", string(message))
				continue
			}

			fmt.Printf("New transaction\nSig: %s\n", signature)
		}
	}
}
```

As you can see its much more _verbose_ than the token minting solution, but here we are directly "talking" to the blockchain, without any intermediate layer whatsoever.

![token migration monitor program](/assets/Screenshot%202025-03-16%20at%2000.22.00.png)

---
This is just a draft of an idea that could be implemented.

Of course there are a lot of technical difficulties to solve, but its not an impossible work neither, as the many emerging Pumpfun tokens trading platform emerging which are generating a massive amount of revenue by charging a generally ~1% swap fee to the users.

**Daily Revenue** as of _03-16-2025_:
- [Photon](https://photon-sol.tinyastro.io/): $517,328

- [BullX](https://bullx.io/): $441,037

Not a bad business I'd say.

---

If you enjoyed this article and want to support me, help me grow my new [X profile](https://x.com/paolousdc). 
